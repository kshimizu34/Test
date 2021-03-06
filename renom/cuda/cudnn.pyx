import contextlib
import numpy as np
cimport cudnn as cd
from libc.stdint cimport uintptr_t
from renom.core import get_gpu
from renom.config import precision
from cuda_utils cimport _VoidPtr

cdef cudnnTensorFormat_t tensor_format = cd.cudnnTensorFormat_t.CUDNN_TENSOR_NCHW
cudnn_handle = []


@contextlib.contextmanager
def cudnn_handler(device=None):
    global cudnn_handle
    handler = None
    if cudnn_handle:
        handler = cudnn_handle[0]
    else:
        handler = createCudnnHandler()
        cudnn_handle.append(handler)
    yield <uintptr_t> handler


def check(cd.cudnnStatus_t status):
    if status == cd.cudnnStatus_t.CUDNN_STATUS_SUCCESS:
        return
    else:
        error = cd.cudnnGetErrorString(status)
        raise Exception(error)


def createCudnnHandler():
    cdef cudnnHandle_t handle
    cudnnCreate( & handle)
    return <uintptr_t> handle


def createTensorDescriptor(shape, dtype=np.float32):
    cdef cudnnTensorDescriptor_t desc
    cdef int n, c, h, w
    n, c, h, w = list(shape) + [1] * (4 - len(shape))
    check(cd.cudnnCreateTensorDescriptor(& desc))
    check(cd.cudnnSetTensor4dDescriptor(desc, tensor_format,
                                        data_type(dtype), n, c, h, w))
    return <uintptr_t> desc


cdef data_type(dtype):
    if dtype == np.float32:
        return cd.cudnnDataType_t.CUDNN_DATA_FLOAT
    elif dtype == np.float64:
        return cd.cudnnDataType_t.CUDNN_DATA_DOUBLE
    elif dtype == np.float16:
        return cd.cudnnDataType_t.CUDNN_DATA_HALF
    else:
        raise Exception("{} is not supported type.".format(dtype))


cdef class TensorDesc(object):

    cdef cudnnTensorDescriptor_t _desc

    def __init__(self, shape, dtype=precision):
        cdef cudnnTensorDescriptor_t desc
        cdef int n, c, h, w
        n, c, h, w = list(shape) + [1] * (4 - len(shape))
        check(cd.cudnnCreateTensorDescriptor(& desc))
        check(cd.cudnnSetTensor4dDescriptor(desc, tensor_format,
                                            data_type(dtype), n, c, h, w))
        self._desc = <cudnnTensorDescriptor_t> <uintptr_t> desc

    cdef cudnnTensorDescriptor_t desc(self):
        return self._desc

    def __del__(self):
        check(cd.cudnnDestroyTensorDescriptor(self._desc))
        

cdef getTensorDescriptor(desc):
    cdef int n, c, h, w, ns, cs, hs, ws
    cdef cudnnDataType_t dtype
    cdef cudnnTensorDescriptor_t c_desc = <cudnnTensorDescriptor_t> <uintptr_t> desc
    cudnnGetTensor4dDescriptor(
        c_desc,
        & dtype,    # image data type
        & n,        # number of inputs (batch size)
        & c,        # number of input feature maps
        & h,        # height of input section
        & w,        # width of input section
        & ns,
        & cs,
        & hs,
        & ws)
    return n, c, h, w, ns, cs, hs, ws, <int> dtype


def createConvplutionDescriptor(padding, stride, dtype):
    cdef cudnnConvolutionDescriptor_t conv_desc
    cdef int pad_h, pad_w, u, v, upscalex, upscaley
    cdef cudnnConvolutionMode_t mode

    pad_h, pad_w = padding
    u, v = stride
    upscalex, upscaley = 1, 1

    check(cudnnCreateConvolutionDescriptor(& conv_desc))
    check(cudnnSetConvolution2dDescriptor_v5(
        conv_desc, pad_h, pad_w, u, v, upscalex, upscaley, mode, data_type(dtype)))
    return <uintptr_t> conv_desc


def createPoolingDescriptor(filter, padding, stride, pool_mode):
    cdef cudnnPoolingDescriptor_t pool_desc
    cdef int pad_h, pad_w, u, v, upscalex, upscaley
    cdef cudnnPoolingMode_t mode = cudnnPoolingMode_t.CUDNN_POOLING_MAX if pool_mode == 0 else \
                                        cudnnPoolingMode_t.CUDNN_POOLING_AVERAGE_COUNT_INCLUDE_PADDING
    cdef cudnnNanPropagation_t nan_prop = cudnnNanPropagation_t.CUDNN_NOT_PROPAGATE_NAN

    w, h = filter
    pad_h, pad_w = padding
    u, v = stride

    check(cudnnCreatePoolingDescriptor(& pool_desc))
    check(cudnnSetPooling2dDescriptor(
        pool_desc, mode, nan_prop, w, h, pad_h, pad_w, u, v))
    return <uintptr_t> pool_desc


def createLRNDescriptor(n, a, b, k):
    cdef cudnnLRNDescriptor_t lrn_desc
    cdef cudnnConvolutionMode_t mode

    check(cudnnCreateLRNDescriptor(& lrn_desc))
    check(cudnnSetLRNDescriptor(
        lrn_desc, n, a, b, k))
    return <uintptr_t> lrn_desc


def cuPoolingForward(handle, pool_desc, x, y):
    cdef cudnnHandle_t handler = <cd.cudnnHandle_t> <uintptr_t> handle

    cdef _VoidPtr alf = _VoidPtr(np.array([1.0], dtype=x.dtype))
    cdef _VoidPtr bt = _VoidPtr(np.array([0.0], dtype=x.dtype))

    cdef TensorDesc xDesc = TensorDesc(x.shape, dtype=x.dtype)
    cdef TensorDesc yDesc = TensorDesc(y.shape, dtype=y.dtype)

    check(cudnnPoolingForward(
        handler,
        <cudnnPoolingDescriptor_t> <uintptr_t> pool_desc,
        alf.ptr,
        xDesc.desc(),
        <const void *> <uintptr_t> get_gpu(x)._ptr,
        bt.ptr,
        yDesc.desc(),
        <void *> <uintptr_t> get_gpu(y)._ptr))


def cuPoolingBackward(handle, pool_desc, x, y, dy, dx):
    cdef cudnnHandle_t handler = <cd.cudnnHandle_t> <uintptr_t> handle

    cdef _VoidPtr alf = _VoidPtr(np.array([1.0], dtype=x.dtype))
    cdef _VoidPtr bt = _VoidPtr(np.array([0.0], dtype=x.dtype))
    cdef TensorDesc xDesc = TensorDesc(x.shape, dtype=x.dtype)
    cdef TensorDesc yDesc = TensorDesc(y.shape, dtype=y.dtype)

    check(cudnnPoolingBackward(
        handler,
        <cudnnPoolingDescriptor_t> <uintptr_t> pool_desc,
        alf.ptr,
        yDesc.desc(),
        <const void *> <uintptr_t> get_gpu(y)._ptr,
        yDesc.desc(),
        <const void *> <uintptr_t> get_gpu(dy)._ptr,
        xDesc.desc(),
        <const void *> <uintptr_t> get_gpu(x)._ptr,
        bt.ptr,
        xDesc.desc(),
        <void *> <uintptr_t> get_gpu(dx)._ptr))


def createFilterDescriptor(shape, dtype):
    cdef cudnnFilterDescriptor_t filter_desc
    cdef int k, c, h, w
    k, c, h, w = list(shape) + [1] * (4 - len(shape))
    check(cudnnCreateFilterDescriptor(& filter_desc))
    check(cudnnSetFilter4dDescriptor(filter_desc, data_type(
        dtype), tensor_format, k, c, h, w))
    return <uintptr_t> filter_desc


def cuBatchNormalizatoinForward(handle, x, mean, var, w, b, y, rm, rv, momentum=0.0, mode=None, inference=False, eps=1e-5):
    cdef cudnnHandle_t handler = <cd.cudnnHandle_t> <uintptr_t> handle

    cdef _VoidPtr alf = _VoidPtr(np.array([1.0], dtype=x.dtype))
    cdef _VoidPtr bt = _VoidPtr(np.array([0.0], dtype=x.dtype))

    cdef cudnnBatchNormMode_t md
    cdef TensorDesc xDesc = TensorDesc(x.shape, dtype=x.dtype)
    cdef TensorDesc wDesc = TensorDesc(w.shape, dtype=w.dtype)
    cdef TensorDesc yDesc = TensorDesc(y.shape, dtype=y.dtype)
    cdef void * mean_ptr = <void *> <uintptr_t> getattr(get_gpu(mean), "_ptr", 0)
    cdef void * var_ptr = <void *> <uintptr_t> getattr(get_gpu(var), "_ptr", 0)

    cdef double epsilon = eps
    cdef double exponentialAverageFactor = momentum

    md = cudnnBatchNormMode_t.CUDNN_BATCHNORM_SPATIAL if mode == 1 else cudnnBatchNormMode_t.CUDNN_BATCHNORM_PER_ACTIVATION

    if not inference:
        check(cudnnBatchNormalizationForwardTraining(
            handler,
            md,
            alf.ptr,
            bt.ptr,
            xDesc.desc(),
            <const void *> <uintptr_t> get_gpu(x)._ptr,
            yDesc.desc(),
            <void *> <uintptr_t> get_gpu(y)._ptr,
            wDesc.desc(),
            <const void *> <uintptr_t> get_gpu(w)._ptr,
            <const void *> <uintptr_t> get_gpu(b)._ptr,
            exponentialAverageFactor,
            mean_ptr,
            var_ptr,
            epsilon,
            <void *> <uintptr_t> get_gpu(rm)._ptr,
            <void *> <uintptr_t> get_gpu(rv)._ptr))
    else:
        check(cudnnBatchNormalizationForwardInference(
            handler,
            md,
            alf.ptr,
            bt.ptr,
            xDesc.desc(),
            <const void *> <uintptr_t> get_gpu(x)._ptr,
            yDesc.desc(),
            <void *> <uintptr_t> get_gpu(y)._ptr,
            wDesc.desc(),
            <const void *> <uintptr_t> get_gpu(w)._ptr,
            <const void *> <uintptr_t> get_gpu(b)._ptr,
            mean_ptr,
            var_ptr,
            epsilon))


def cuBatchNormalizatoinBackward(handle, x, w, dy, saved_mean, saved_var, dx, dw, db, mode=None):
    cdef cudnnHandle_t handler = <cd.cudnnHandle_t> <uintptr_t> handle

    cdef _VoidPtr alf = _VoidPtr(np.array([1.0], dtype=x.dtype))
    cdef _VoidPtr bt = _VoidPtr(np.array([0.0], dtype=x.dtype))

    cdef cudnnBatchNormMode_t md
    cdef TensorDesc xDesc = TensorDesc(x.shape, dtype=x.dtype)
    cdef TensorDesc dwDesc = TensorDesc(dw.shape, dtype=dw.dtype)
    cdef TensorDesc dyDesc = TensorDesc(dy.shape, dtype=dy.dtype)
    cdef double epsilon = 1e-5

    md = cudnnBatchNormMode_t.CUDNN_BATCHNORM_SPATIAL if mode == 1 else cudnnBatchNormMode_t.CUDNN_BATCHNORM_PER_ACTIVATION

    check(cudnnBatchNormalizationBackward(
        handler,
        md,
        alf.ptr,
        bt.ptr,
        alf.ptr,
        bt.ptr,
        xDesc.desc(),
        <const void *> <uintptr_t> get_gpu(x)._ptr,
        dyDesc.desc(),
        <const void *> <uintptr_t> get_gpu(dy)._ptr,
        xDesc.desc(),
        <void *> <uintptr_t> get_gpu(dx)._ptr,
        dwDesc.desc(),
        <const void *> <uintptr_t> get_gpu(w)._ptr,
        <void *> <uintptr_t> get_gpu(dw)._ptr,
        <void *> <uintptr_t> get_gpu(db)._ptr,
        epsilon,
        <const void *> <uintptr_t> get_gpu(saved_mean)._ptr,
        <const void *> <uintptr_t> get_gpu(saved_var)._ptr))


def cuGetConvolutionFwdAlgo(handle, conv_desc, filter_desc, x, y):
    cdef cudnnHandle_t handler = <cd.cudnnHandle_t> <uintptr_t> handle
    cdef cudnnConvolutionFwdAlgo_t algo
    cdef cudnnConvolutionFwdPreference_t pref = cudnnConvolutionFwdPreference_t.CUDNN_CONVOLUTION_FWD_NO_WORKSPACE
    cdef TensorDesc xDesc = TensorDesc(x.shape, dtype=x.dtype)
    cdef cudnnFilterDescriptor_t wDesc = <cudnnFilterDescriptor_t> <uintptr_t> filter_desc
    cdef TensorDesc yDesc = TensorDesc(y.shape, dtype=y.dtype)
    cdef cudnnConvolutionDescriptor_t convDesc = <cudnnConvolutionDescriptor_t> <uintptr_t> conv_desc

    check(cudnnGetConvolutionForwardAlgorithm(
        handler,
        xDesc.desc(),
        wDesc,
        convDesc,
        yDesc.desc(),
        pref,
        0,
        & algo))
    return <uintptr_t> algo


def cuConvolutionForward(handle, conv_desc, filter_desc, x, w, y):
    cdef cudnnHandle_t handler = <cd.cudnnHandle_t> <uintptr_t> handle

    cdef _VoidPtr alf = _VoidPtr(np.array([1.0], dtype=x.dtype))
    cdef _VoidPtr bt = _VoidPtr(np.array([0.0], dtype=x.dtype))

    cdef TensorDesc xDesc = TensorDesc(x.shape, dtype=x.dtype)
    cdef TensorDesc yDesc = TensorDesc(y.shape, dtype=y.dtype)
    # cdef cudnnConvolutionFwdAlgo_t algo = <cudnnConvolutionFwdAlgo_t><uintptr_t>cuGetConvolutionFwdAlgo(handle, conv_desc, filter_desc, x, y)
    # output of CUDNN_CONVOLUTION_FWD_ALGO_IMPLICIT_GEMM is not deterministic
    cdef cudnnConvolutionFwdAlgo_t algo = cudnnConvolutionFwdAlgo_t.CUDNN_CONVOLUTION_FWD_ALGO_IMPLICIT_GEMM
    cdef int workSpace = 0

    check(cudnnConvolutionForward(
        handler,
        alf.ptr,
        xDesc.desc(),
        <const void *> <uintptr_t> get_gpu(x)._ptr,
        <cudnnFilterDescriptor_t> <uintptr_t> filter_desc,
        <void *> <uintptr_t> get_gpu(w)._ptr,
        <cudnnConvolutionDescriptor_t> <uintptr_t> conv_desc,
        algo,
        <void *>workSpace,
        0,
        bt.ptr,
        yDesc.desc(),
        <void *> <uintptr_t> get_gpu(y)._ptr))


def cuConvolutionBackward(handle, conv_desc, filter_desc, x, w, dy, dw, db, dx):
    cdef _VoidPtr alf = _VoidPtr(np.array([1.0], dtype=x.dtype))
    cdef _VoidPtr bt = _VoidPtr(np.array([0.0], dtype=x.dtype))

    cdef cudnnHandle_t handler = <cd.cudnnHandle_t> <uintptr_t> handle
    cdef TensorDesc xDesc = TensorDesc(x.shape, dtype=x.dtype)
    cdef TensorDesc dyDesc = TensorDesc(dy.shape, dtype=dy.dtype)
    cdef TensorDesc dbDesc = TensorDesc(db.shape, dtype=db.dtype)
    cdef cudnnConvolutionBwdFilterAlgo_t algo_filter = cudnnConvolutionBwdFilterAlgo_t.CUDNN_CONVOLUTION_BWD_FILTER_ALGO_0
    cdef cudnnConvolutionBwdDataAlgo_t algo_data = cudnnConvolutionBwdDataAlgo_t.CUDNN_CONVOLUTION_BWD_DATA_ALGO_0
    cdef int workSpace = 0

    check(cudnnConvolutionBackwardFilter(
        handler,
        alf.ptr,
        xDesc.desc(),
        <const void *> <uintptr_t> get_gpu(x)._ptr,
        dyDesc.desc(),
        <const void *> <uintptr_t> get_gpu(dy)._ptr,
        <cudnnConvolutionDescriptor_t> <uintptr_t> conv_desc,
        algo_filter,
        <void *>workSpace,
        0,
        bt.ptr,
        <cudnnFilterDescriptor_t> <uintptr_t> filter_desc,
        <void *> <uintptr_t> get_gpu(dw)._ptr))

    check(cudnnConvolutionBackwardData(
        handler,
        alf.ptr,
        <cudnnFilterDescriptor_t> <uintptr_t> filter_desc,
        <void *> <uintptr_t> get_gpu(w)._ptr,
        dyDesc.desc(),
        <const void *> <uintptr_t> get_gpu(dy)._ptr,
        <cudnnConvolutionDescriptor_t> <uintptr_t> conv_desc,
        algo_data,
        <void *>workSpace,
        0,
        bt.ptr,
        xDesc.desc(),
        <void *> <uintptr_t> get_gpu(dx)._ptr))

    check(cudnnConvolutionBackwardBias(
        handler,
        alf.ptr,
        dyDesc.desc(),
        <const void *> <uintptr_t> get_gpu(dy)._ptr,
        bt.ptr,
        dbDesc.desc(),
        <void *> <uintptr_t> get_gpu(db)._ptr))


def cuConvolutionBackwardData(handle, conv_desc, filter_desc, w, dy, dx):
    cdef _VoidPtr alf = _VoidPtr(np.array([1.0], dtype=w.dtype))
    cdef _VoidPtr bt = _VoidPtr(np.array([0.0], dtype=w.dtype))

    cdef cudnnHandle_t handler = <cd.cudnnHandle_t> <uintptr_t> handle
    cdef TensorDesc xDesc = TensorDesc(dx.shape, dtype=dx.dtype)
    cdef TensorDesc dyDesc = TensorDesc(dy.shape, dtype=dy.dtype)
    cdef cudnnConvolutionBwdDataAlgo_t algo_data = cudnnConvolutionBwdDataAlgo_t.CUDNN_CONVOLUTION_BWD_DATA_ALGO_0
    cdef int workSpace = 0

    check(cudnnConvolutionBackwardData(
        handler,
        alf.ptr,
        <cudnnFilterDescriptor_t> <uintptr_t> filter_desc,
        <void *> <uintptr_t> get_gpu(w)._ptr,
        dyDesc.desc(),
        <const void *> <uintptr_t> get_gpu(dy)._ptr,
        <cudnnConvolutionDescriptor_t> <uintptr_t> conv_desc,
        algo_data,
        <void *>workSpace,
        0,
        bt.ptr,
        xDesc.desc(),
        <void *> <uintptr_t> get_gpu(dx)._ptr))


def cuConvolutionBackwardFilter(handle, conv_desc, filter_desc, x, dy, dw):
    cdef _VoidPtr alf = _VoidPtr(np.array([1.0], dtype=x.dtype))
    cdef _VoidPtr bt = _VoidPtr(np.array([0.0], dtype=x.dtype))

    cdef cudnnHandle_t handler = <cd.cudnnHandle_t> <uintptr_t> handle
    cdef TensorDesc xDesc = TensorDesc(x.shape, dtype=x.dtype)
    cdef TensorDesc dyDesc = TensorDesc(dy.shape, dtype=dy.dtype)
    cdef cudnnConvolutionBwdFilterAlgo_t algo_filter = cudnnConvolutionBwdFilterAlgo_t.CUDNN_CONVOLUTION_BWD_FILTER_ALGO_0
    cdef int workSpace = 0

    check(cudnnConvolutionBackwardFilter(
        handler,
        alf.ptr,
        xDesc.desc(),
        <const void *> <uintptr_t> get_gpu(x)._ptr,
        dyDesc.desc(),
        <const void *> <uintptr_t> get_gpu(dy)._ptr,
        <cudnnConvolutionDescriptor_t> <uintptr_t> conv_desc,
        algo_filter,
        <void *>workSpace,
        0,
        bt.ptr,
        <cudnnFilterDescriptor_t> <uintptr_t> filter_desc,
        <void *> <uintptr_t> get_gpu(dw)._ptr))


def cuConvolutionBackwardBias(handle, dy, db):
    cdef _VoidPtr alf = _VoidPtr(np.array([1.0], dtype=dy.dtype))
    cdef _VoidPtr bt = _VoidPtr(np.array([0.0], dtype=dy.dtype))

    cdef cudnnHandle_t handler = <cd.cudnnHandle_t> <uintptr_t> handle
    cdef TensorDesc dyDesc = TensorDesc(dy.shape, dtype=dy.dtype)
    cdef TensorDesc dbDesc = TensorDesc(db.shape, dtype=db.dtype)

    check(cudnnConvolutionBackwardBias(
        handler,
        alf.ptr,
        dyDesc.desc(),
        <const void *> <uintptr_t> get_gpu(dy)._ptr,
        bt.ptr,
        dbDesc.desc(),
        <void *> <uintptr_t> get_gpu(db)._ptr))


def cuSoftmaxForward(handle, x, y, mode=0):
    cdef _VoidPtr a = _VoidPtr(np.array([1.0], dtype=x.dtype))
    cdef _VoidPtr b = _VoidPtr(np.array([0.0], dtype=x.dtype))

    cdef cudnnHandle_t handler = <cd.cudnnHandle_t> <uintptr_t> handle
    cdef TensorDesc yDesc = TensorDesc(y.shape, dtype=y.dtype)
    cdef cd.cudnnSoftmaxMode_t md = cd.cudnnSoftmaxMode_t.CUDNN_SOFTMAX_MODE_CHANNEL if mode == 1 else cd.cudnnSoftmaxMode_t.CUDNN_SOFTMAX_MODE_INSTANCE

    check(cd.cudnnSoftmaxForward(
        handler,
        cd.cudnnSoftmaxAlgorithm_t.CUDNN_SOFTMAX_ACCURATE,
        md,
        <const void *> a.ptr,
        yDesc.desc(),
        <const void *> <uintptr_t> get_gpu(x)._ptr,
        <const void *> b.ptr,
        yDesc.desc(),
        <void *> <uintptr_t> get_gpu(y)._ptr))


def cuLocalResponseNormalizationForward(handle, lrn_desc, x, y):
    cdef cudnnHandle_t handler = <cd.cudnnHandle_t> <uintptr_t> handle
    cdef cudnnLRNMode_t mode = cudnnLRNMode_t.CUDNN_LRN_CROSS_CHANNEL_DIM1
    cdef TensorDesc xDesc = TensorDesc(x.shape, dtype=x.dtype)
    cdef TensorDesc yDesc = TensorDesc(y.shape, dtype=y.dtype)

    cdef _VoidPtr d = _VoidPtr(np.array([1.0], dtype=x.dtype))
    cdef _VoidPtr e = _VoidPtr(np.array([0.0], dtype=x.dtype))

    check(cudnnLRNCrossChannelForward(
        handler,
        <cudnnLRNDescriptor_t> <uintptr_t> lrn_desc,
        mode,
        d.ptr,
        xDesc.desc(),
        <const void *> <uintptr_t> get_gpu(x)._ptr,
        e.ptr,
        yDesc.desc(),
        <void *> <uintptr_t> get_gpu(y)._ptr))


def cuLocalResponseNormalizationBackward(handle, lrn_desc, x, y, dx, dy):
    cdef cudnnHandle_t handler = <cd.cudnnHandle_t> <uintptr_t> handle
    cdef cudnnLRNMode_t mode = cudnnLRNMode_t.CUDNN_LRN_CROSS_CHANNEL_DIM1
    cdef TensorDesc xDesc = TensorDesc(x.shape, dtype=x.dtype)
    cdef TensorDesc yDesc = TensorDesc(y.shape, dtype=y.dtype)

    cdef _VoidPtr a = _VoidPtr(np.array([1.0], dtype=x.dtype))
    cdef _VoidPtr b = _VoidPtr(np.array([0.0], dtype=x.dtype))

    check(cudnnLRNCrossChannelBackward(
        handler,
        <cudnnLRNDescriptor_t> <uintptr_t> lrn_desc,
        mode,
        a.ptr,
        yDesc.desc(),
        <void *> <uintptr_t> get_gpu(y)._ptr,
        yDesc.desc(),
        <const void *> <uintptr_t> get_gpu(dy)._ptr,
        xDesc.desc(),
        <const void *> <uintptr_t> get_gpu(x)._ptr,
        b.ptr,
        xDesc.desc(),
        <void *> <uintptr_t> get_gpu(dx)._ptr))
