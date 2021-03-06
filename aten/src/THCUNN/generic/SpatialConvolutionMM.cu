#ifndef THC_GENERIC_FILE
#define THC_GENERIC_FILE "generic/SpatialConvolutionMM.cu"
#else

static inline void THNN_(SpatialConvolutionMM_shapeCheck)(
                         THCState *state,
                         THCTensor *input, THCTensor *gradOutput,
                         THCTensor *weight, THCTensor *bias,
                         int kH, int kW, int dH, int dW, int padH, int padW,
                         int weight_nullable) {
  THArgCheck(kW > 0 && kH > 0, 9,
             "kernel size should be greater than zero, but got kH: %d kW: %d", kH, kW);
  THArgCheck(dW > 0 && dH > 0, 11,
             "stride should be greater than zero, but got dH: %d dW: %d", dH, dW);

  if (weight != NULL) {
    THCUNN_argCheck(state, !weight->is_empty() && (weight->dim() == 2 || weight->dim() == 4), 5, weight,
                    "non-empty 2D or 4D weight tensor expected, but got: %s");
    if (bias != NULL) {
      THCUNN_check_dim_size(state, bias, 1, 0, weight->size(0));
    }
  } else if (!weight_nullable) {
    THError("weight tensor is expected to be non-nullable");
  }

  int ndim = input->dim();
  int dimf = 0;
  int dimh = 1;
  int dimw = 2;

  if (ndim == 4) {
    dimf++;
    dimh++;
    dimw++;
  }

  THCUNN_argCheck(state, !input->is_empty() && (ndim == 3 || ndim == 4), 2, input,
                  "non-empty 3D or 4D input tensor expected but got: %s");

  int64_t inputHeight  = input->size(dimh);
  int64_t inputWidth   = input->size(dimw);

  int64_t exactInputHeight = inputHeight + 2 * padH;
  int64_t exactInputWidth = inputWidth + 2 * padW;

  if (exactInputHeight < kH || exactInputWidth < kW) {
    THError("Calculated padded input size per channel: (%ld x %ld). "
      "Kernel size: (%ld x %ld). Kernel size can't be greater than actual input size",
      exactInputHeight, exactInputWidth, kH, kW);
  }

  int64_t outputHeight = (exactInputHeight - kH) / dH + 1;
  int64_t outputWidth  = (exactInputWidth - kW) / dW + 1;

  if (outputWidth < 1 || outputHeight < 1) {
    THError("Given input size per channel: (%ld x %ld). "
      "Calculated output size per channel: (%ld x %ld). Output size is too small",
      inputHeight, inputWidth, outputHeight, outputWidth);
  }

  if (weight != NULL) {
    int64_t nInputPlane = weight->size(1);
    if (weight->dim() == 2) {
      nInputPlane /= (kH * kW);
    }
    THCUNN_check_dim_size(state, input, ndim, dimf, nInputPlane);
  }

  if (gradOutput != NULL) {
    if (weight != NULL) {
      int64_t nOutputPlane = weight->size(0);
      THCUNN_check_dim_size(state, gradOutput, ndim, dimf, nOutputPlane);
    } else if (bias != NULL) {
      int64_t nOutputPlane = bias->size(0);
      THCUNN_check_dim_size(state, gradOutput, ndim, dimf, nOutputPlane);
    }
    THCUNN_check_dim_size(state, gradOutput, ndim, dimh, outputHeight);
    THCUNN_check_dim_size(state, gradOutput, ndim, dimw, outputWidth);
  }
}

void THNN_(SpatialConvolutionMM_updateOutput)(
           THCState *state,
           THCTensor *input,
           THCTensor *output,
           THCTensor *weight,
           THCTensor *bias,
           THCTensor *columns,
           THCTensor *ones,
           int kW, int kH,
           int dW, int dH,
           int padW, int padH) {

  THCUNN_assertSameGPU(state, 5, input, output, weight, columns, ones);
  if (bias) {
    THCUNN_assertSameGPU(state, 2, weight, bias);
  }
  THArgCheck(THCTensor_(isContiguous)(state, weight), 4,
             "weight tensor has to be contiguous");
  THArgCheck(!bias || THCTensor_(isContiguous)(state, bias), 5,
             "bias tensor has to be contiguous");

  int freeWeight = 0;

  // Params:
  int nInputPlane = weight->dim() == 2 ? weight->size(1)/(kH*kW) : weight->size(1);
  int nOutputPlane = weight->size(0);

  if (weight->dim() == 4) {
    int64_t s1 = weight->size(0);
    int64_t s2 = weight->size(1) * weight->size(2) * weight->size(3);
    weight = THCTensor_(newWithStorage2d)(state, THTensor_getStoragePtr(weight), weight->storage_offset(), s1, -1, s2, -1);
    freeWeight = 1;
  }

  THNN_(SpatialConvolutionMM_shapeCheck)
       (state, input, NULL, weight, bias, kH, kW, dH, dW, padH, padW, 0);

  input = THCTensor_(newContiguous)(state, input);
  int is_batch = 1;
  if (input->dim() == 3) {
    // Force batch
    is_batch = 0;
    THCTensor_(resize4d)(state, input, 1, input->size(0), input->size(1), input->size(2));
  }

  int64_t inputWidth   = input->size(3);
  int64_t inputHeight  = input->size(2);
  int64_t outputWidth  = (inputWidth + 2*padW - kW) / dW + 1;
  int64_t outputHeight = (inputHeight + 2*padH - kH) / dH + 1;

  // Batch size + input planes
  int64_t batchSize = input->size(0);

  // Resize output
  THCTensor_(resize4d)(state, output, batchSize, nOutputPlane, outputHeight, outputWidth);

  // Resize temporary columns
  THCTensor_(resize2d)(state, columns, nInputPlane*kW*kH, outputHeight*outputWidth);

  // Define a buffer of ones, for bias accumulation
  // Note: this buffer can be shared with other modules, it only ever gets increased,
  // and always contains ones.
  if (ones->dim() != 2 || ones->size(0)*ones->size(1) < outputHeight*outputWidth) {
    // Resize plane and fill with ones...
    THCTensor_(resize2d)(state, ones, outputHeight, outputWidth);
    THCTensor_(fill)(state, ones, ScalarConvert<int, real>::to(1));
  }

  // Helpers
  THCTensor *input_n = THCTensor_(new)(state);
  THCTensor *output_n = THCTensor_(new)(state);

  // For each elt in batch, do:
  for (int elt = 0; elt < batchSize; elt ++) {
    // Matrix mulitply per output:
    THCTensor_(select)(state, input_n, input, 0, elt);
    THCTensor_(select)(state, output_n, output, 0, elt);

    // Do Bias first:
    // M,N,K are dims of matrix A and B
    // (see http://docs.nvidia.com/cuda/cublas/#cublas-lt-t-gt-gemm)
    int64_t m_ = nOutputPlane;
    int64_t n_ = outputHeight * outputWidth;
    int64_t k_ = 1;

    // Do GEMM (note: this is a bit confusing because gemm assumes column-major matrices)
    if (bias) {
      #ifdef THC_REAL_IS_FLOAT
      THCudaBlas_Sgemm(
      #elif defined(THC_REAL_IS_HALF)
      THCudaBlas_Hgemm(
      #elif defined(THC_REAL_IS_DOUBLE)
      THCudaBlas_Dgemm(
      #endif
          state,
          't', 'n',
          n_, m_, k_,
          ScalarConvert<int, real>::to(1),
          THCTensor_(data)(state, ones), k_,
          THCTensor_(data)(state, bias), k_,
          ScalarConvert<int, real>::to(0),
          THCTensor_(data)(state, output_n), n_
      );
    } else {
      THCTensor_(zero)(state, output_n);
    }

    // Extract columns:
    im2col(
      THCState_getCurrentStream(state),
      THCTensor_(data)(state, input_n),
      nInputPlane, inputHeight, inputWidth,
      outputHeight, outputWidth,
      kH, kW, padH, padW, dH, dW,
      1, 1, THCTensor_(data)(state, columns)
    );

    // M,N,K are dims of matrix A and B
    // (see http://docs.nvidia.com/cuda/cublas/#cublas-lt-t-gt-gemm)
    int64_t m = nOutputPlane;
    int64_t n = columns->size(1);
    int64_t k = nInputPlane*kH*kW;

    // Do GEMM (note: this is a bit confusing because gemm assumes column-major matrices)
    #ifdef THC_REAL_IS_FLOAT
    THCudaBlas_Sgemm(
    #elif defined(THC_REAL_IS_HALF)
    THCudaBlas_Hgemm(
    #elif defined(THC_REAL_IS_DOUBLE)
    THCudaBlas_Dgemm(
    #endif
        state,
        'n', 'n',
        n, m, k,
        ScalarConvert<int, real>::to(1),
        THCTensor_(data)(state, columns), n,
        THCTensor_(data)(state, weight), k,
        ScalarConvert<int, real>::to(1),
        THCTensor_(data)(state, output_n), n
    );
  }

  // Free
  THCTensor_(free)(state, input_n);
  THCTensor_(free)(state, output_n);
  if (freeWeight)
    THCTensor_(free)(state, weight);

  // Resize output
  if (is_batch == 0) {
    THCTensor_(resize3d)(state, output, nOutputPlane, outputHeight, outputWidth);
    THCTensor_(resize3d)(state, input, nInputPlane, inputHeight, inputWidth);
  }

  THCTensor_(free)(state, input);
}

void THNN_(SpatialConvolutionMM_updateGradInput)(
           THCState *state,
           THCTensor *input,
           THCTensor *gradOutput,
           THCTensor *gradInput,
           THCTensor *weight,
           THCTensor *gradColumns,
           THCTensor *ones,
           int kW, int kH,
           int dW, int dH,
           int padW, int padH) {

  THCUNN_assertSameGPU(state, 5, input, gradOutput, weight,
                       gradColumns, gradInput);
  THArgCheck(THCTensor_(isContiguous)(state, weight), 4,
             "weight tensor has to be contiguous");

  THNN_(SpatialConvolutionMM_shapeCheck)
       (state, input, gradOutput, weight, NULL, kH, kW, dH, dW, padH, padW, 0);

  // Params
  int nInputPlane = weight->dim() == 2 ? weight->size(1)/(kW*kH) : weight->size(1);
  int nOutputPlane = weight->size(0);

  int freeWeight = 0;
  if (weight->dim() == 4) {
    int64_t s1 = weight->size(0);
    int64_t s2 = weight->size(1) * weight->size(2) * weight->size(3);
    weight = THCTensor_(newWithStorage2d)(state, THTensor_getStoragePtr(weight), weight->storage_offset(), s1, -1, s2, -1);
    freeWeight = 1;
  }

  input = THCTensor_(newContiguous)(state, input);
  gradOutput = THCTensor_(newContiguous)(state, gradOutput);

  int is_batch = 1;
  if (input->dim() == 3) {
    // Force batch
    is_batch = 0;
    THCTensor_(resize4d)(state, input, 1, input->size(0), input->size(1), input->size(2));
    THCTensor_(resize4d)(state, gradOutput, 1, gradOutput->size(0), gradOutput->size(1), gradOutput->size(2));
  }

  int64_t inputWidth   = input->size(3);
  int64_t inputHeight  = input->size(2);
  int64_t outputWidth  = (inputWidth + 2*padW - kW) / dW + 1;
  int64_t outputHeight = (inputHeight + 2*padH - kH) / dH + 1;

  // Batch size + input planes
  int64_t batchSize = input->size(0);

  // Resize output
  THCTensor_(resize4d)(state, gradInput, batchSize, nInputPlane, inputHeight, inputWidth);

  // Resize temporary columns
  THCTensor_(resize2d)(state, gradColumns, nInputPlane*kW*kH, outputHeight*outputWidth);

  // Helpers
  THCTensor *gradInput_n = THCTensor_(new)(state);
  THCTensor *gradOutput_n = THCTensor_(new)(state);

  // For each elt in batch, do:
  for (int elt = 0; elt < batchSize; elt ++) {
    // Matrix mulitply per sample:
    THCTensor_(select)(state, gradInput_n, gradInput, 0, elt);
    THCTensor_(select)(state, gradOutput_n, gradOutput, 0, elt);

    // M,N,K are dims of matrix A and B
    // (see http://docs.nvidia.com/cuda/cublas/#cublas-lt-t-gt-gemm)
    int64_t m = nInputPlane*kW*kH;
    int64_t n = gradColumns->size(1);
    int64_t k = nOutputPlane;

    // Do GEMM (note: this is a bit confusing because gemm assumes column-major matrices)
    #ifdef THC_REAL_IS_FLOAT
    THCudaBlas_Sgemm(
    #elif defined(THC_REAL_IS_HALF)
    THCudaBlas_Hgemm(
    #elif defined(THC_REAL_IS_DOUBLE)
    THCudaBlas_Dgemm(
    #endif
        state,
        'n', 't',
        n, m, k,
        ScalarConvert<int, real>::to(1),
        THCTensor_(data)(state, gradOutput_n), n,
        THCTensor_(data)(state, weight), m,
        ScalarConvert<int, real>::to(0),
        THCTensor_(data)(state, gradColumns), n
    );

    // Unpack columns back into input:
    col2im<real, accreal>(
      THCState_getCurrentStream(state),
      THCTensor_(data)(state, gradColumns),
      nInputPlane, inputHeight, inputWidth, outputHeight, outputWidth, kH, kW, padH, padW, dH, dW,
      1, 1, THCTensor_(data)(state, gradInput_n)
    );
  }

  // Free
  THCTensor_(free)(state, gradInput_n);
  THCTensor_(free)(state, gradOutput_n);
  if (freeWeight)
    THCTensor_(free)(state, weight);

  // Resize output
  if (is_batch == 0) {
    THCTensor_(resize3d)(state, gradOutput, nOutputPlane, outputHeight, outputWidth);
    THCTensor_(resize3d)(state, input, nInputPlane, inputHeight, inputWidth);
    THCTensor_(resize3d)(state, gradInput, nInputPlane, inputHeight, inputWidth);
  }

  THCTensor_(free)(state, input);
  THCTensor_(free)(state, gradOutput);
}

void THNN_(SpatialConvolutionMM_accGradParameters)(
           THCState *state,
           THCTensor *input,
           THCTensor *gradOutput,
           THCTensor *gradWeight,
           THCTensor *gradBias,
           THCTensor *columns,
           THCTensor *ones,
           int kW, int kH,
           int dW, int dH,
           int padW, int padH,
           accreal scale_) {

  real scale = ScalarConvert<accreal, real>::to(scale_);
  THCUNN_assertSameGPU(state, 5, input, gradOutput, gradWeight, gradBias, columns, ones);
  if (gradWeight) {
    THArgCheck(THCTensor_(isContiguous)(state, gradWeight), 4, "gradWeight needs to be contiguous");
  }
  if (gradBias) {
    THArgCheck(THCTensor_(isContiguous)(state, gradBias), 5, "gradBias needs to be contiguous");
    THArgCheck(THCTensor_(isContiguous)(state, ones), 7, "ones needs to be contiguous");
  }

  THNN_(SpatialConvolutionMM_shapeCheck)
       (state, input, gradOutput, gradWeight, gradBias, kH, kW, dH, dW, padH, padW, 1);

  // Params
  input = THCTensor_(newContiguous)(state, input);
  gradOutput = THCTensor_(newContiguous)(state, gradOutput);

  int is_batch = 1;
  if (input->dim() == 3) {
    // Force batch
    is_batch = 0;
    THCTensor_(resize4d)(state, input, 1, input->size(0), input->size(1), input->size(2));
    THCTensor_(resize4d)(state, gradOutput, 1, gradOutput->size(0), gradOutput->size(1), gradOutput->size(2));
  }

  int64_t nInputPlane = input->size(1);
  int64_t nOutputPlane = gradOutput->size(1);

  int freeWeight = 0;
  if (gradWeight && gradWeight->dim() == 4) {
    int64_t s1 = gradWeight->size(0);
    int64_t s2 = gradWeight->size(1) * gradWeight->size(2) * gradWeight->size(3);
    gradWeight = THCTensor_(newWithStorage2d)(state, THTensor_getStoragePtr(gradWeight), gradWeight->storage_offset(), s1, -1, s2, -1);
    freeWeight = 1;
  }

  int64_t inputWidth   = input->size(3);
  int64_t inputHeight  = input->size(2);
  int64_t outputWidth  = (inputWidth + 2*padW - kW) / dW + 1;
  int64_t outputHeight = (inputHeight + 2*padH - kH) / dH + 1;

  // Batch size + input planes
  int64_t batchSize = input->size(0);

  // Define a buffer of ones, for bias accumulation
  if (ones->dim() != 2 || ones->size(0)*ones->size(1) < outputHeight*outputWidth) {
    // Resize plane and fill with ones...
    THCTensor_(resize2d)(state, ones, outputHeight, outputWidth);
    THCTensor_(fill)(state, ones, ScalarConvert<int, real>::to(1));
  }

  // Resize temporary columns
  THCTensor_(resize2d)(state, columns, nInputPlane*kW*kH, outputHeight*outputWidth);

  // Helpers
  THCTensor *input_n = THCTensor_(new)(state);
  THCTensor *gradOutput_n = THCTensor_(new)(state);

  // For each elt in batch, do:
  for (int elt = 0; elt < batchSize; elt ++) {
    // Matrix mulitply per output:
    THCTensor_(select)(state, gradOutput_n, gradOutput, 0, elt);

    // Do Weight:
    if (gradWeight) {
      // Matrix mulitply per output:
      THCTensor_(select)(state, input_n, input, 0, elt);

      // Extract columns:
      im2col(
        THCState_getCurrentStream(state),
        THCTensor_(data)(state, input_n),
        nInputPlane, inputHeight, inputWidth,
        outputHeight, outputWidth,
        kH, kW, padH, padW, dH, dW,
        1, 1, THCTensor_(data)(state, columns)
      );

      // M,N,K are dims of matrix A and B
      // (see http://docs.nvidia.com/cuda/cublas/#cublas-lt-t-gt-gemm)
      int64_t m = nOutputPlane;
      int64_t n = nInputPlane*kW*kH;
      int64_t k = columns->size(1);

      // Do GEMM (note: this is a bit confusing because gemm assumes column-major matrices)
      #ifdef THC_REAL_IS_FLOAT
      THCudaBlas_Sgemm(
      #elif defined(THC_REAL_IS_HALF)
      THCudaBlas_Hgemm(
      #elif defined(THC_REAL_IS_DOUBLE)
      THCudaBlas_Dgemm(
      #endif
          state,
          't', 'n',
          n, m, k,
          scale,
          THCTensor_(data)(state, columns), k,
          THCTensor_(data)(state, gradOutput_n), k,
          ScalarConvert<int, real>::to(1),
          THCTensor_(data)(state, gradWeight), n
      );
    }

    // Do Bias:
    if (gradBias) {
      // M,N,K are dims of matrix A and B
      // (see http://docs.nvidia.com/cuda/cublas/#cublas-lt-t-gt-gemm)
      int64_t m_ = nOutputPlane;
      int64_t k_ = outputHeight * outputWidth;

      // Do GEMV (note: this is a bit confusing because gemv assumes column-major matrices)
      #if defined(THC_REAL_IS_FLOAT) || defined(THC_REAL_IS_DOUBLE)
      #ifdef THC_REAL_IS_FLOAT
      THCudaBlas_Sgemv(
      #elif defined(THC_REAL_IS_DOUBLE)
      THCudaBlas_Dgemv(
      #endif
          state,
          't',
          k_, m_,
          scale,
          THCTensor_(data)(state, gradOutput_n), k_,
          THCTensor_(data)(state, ones), 1,
          ScalarConvert<int, real>::to(1),
          THCTensor_(data)(state, gradBias), 1
      );
      #endif
      #ifdef THC_REAL_IS_HALF
      THCudaBlas_Hgemm(
          state,
          't', 'n',
          m_, 1, k_,
          scale,
          THCTensor_(data)(state, gradOutput_n), k_,
          THCTensor_(data)(state, ones), k_,
          ScalarConvert<int, real>::to(1),
          THCTensor_(data)(state, gradBias), m_
      );
      #endif
    }
  }

  // Free
  THCTensor_(free)(state, input_n);
  THCTensor_(free)(state, gradOutput_n);
  if (freeWeight)
    THCTensor_(free)(state, gradWeight);

  // Resize
  if (is_batch == 0) {
    THCTensor_(resize3d)(state, gradOutput, nOutputPlane, outputHeight, outputWidth);
    THCTensor_(resize3d)(state, input, nInputPlane, inputHeight, inputWidth);
  }

  THCTensor_(free)(state, input);
  THCTensor_(free)(state, gradOutput);
}

#endif
