#include <ATen/jit_macros.h>

#if AT_USE_JITERATOR()

#include <c10/util/variant.h>
#include <c10/cuda/CUDAGuard.h>
#include <ATen/cuda/jiterator.h>
#include <ATen/native/TensorIterator.h>
#include <ATen/cuda/detail/OffsetCalculator.cuh>
#include <ATen/native/cuda/jit_utils.h>
#include <ATen/native/cuda/MemoryAccess.cuh>
#include <ATen/native/cuda/JitLoops.cuh>

#include <iostream>
#include <utility>

namespace at {
namespace native {

#define AT_FOR_8_INPUTS(_)  \
  _(0)                      \
  _(1)                      \
  _(2)                      \
  _(3)                      \
  _(4)                      \
  _(5)                      \
  _(6)                      \
  _(7)

c10::SmallVector<std::string> get_extra_args_typenames(const std::vector<at::Scalar>& extra_args) {
  c10::SmallVector<std::string> args_typenames(extra_args.size());
  for (auto i = 0; i < extra_args.size(); ++i) {
    args_typenames[i] = at::cuda::jit::typeName(extra_args[i].type());
  }
  return args_typenames;
}

int can_vectorize_up_to(at::ScalarType type, char* pointer) {
  switch(type) {
#define DEFINE_CASE(ctype, scalartype)                                   \
    case ScalarType::scalartype : return memory::can_vectorize_up_to<ctype>(pointer);

    AT_FORALL_SCALAR_TYPES_WITH_COMPLEX(DEFINE_CASE)
#undef DEFINE_CASE

    default: TORCH_INTERNAL_ASSERT(false, "Unrecognized ScalarType: ", type);
  }
}

// jitted version of the above
// See Note [Jiterator], this relies on the assumptions enumerated there
int jitted_can_vectorize_up_to(const TensorIteratorBase& iter) {
  const at::ScalarType common_dtype = iter.common_dtype();
  const at::ScalarType result_dtype = common_dtype;

  // Deals with output
  int result = can_vectorize_up_to(result_dtype, static_cast<char*>(iter.data_ptr(0)));

  // Incorporates input(s)
  for (auto i = 1; i < iter.ntensors(); ++i) {
    result = std::min<int>(result, can_vectorize_up_to(common_dtype, static_cast<char*>(iter.data_ptr(i))));
  }

  return result;
}

template<int N>
static std::unique_ptr<OffsetCalculator<N>> make_unique_input_offset_calculator(const TensorIteratorBase& iter) {
  // array size can not be 0, this happens when N == 0
  constexpr int array_size = std::max<int>(N, 1);
  TORCH_INTERNAL_ASSERT(N == iter.ntensors() - iter.noutputs());
  std::array<const int64_t*, array_size> strides;
  int64_t element_sizes[array_size];
  for (int i = 0; i < N; i++) {
    strides[i] = iter.strides(i + iter.noutputs()).data();
    element_sizes[i] = iter.element_size(i + iter.noutputs());
  }
  return std::make_unique<OffsetCalculator<N>>(iter.ndim(), iter.shape().data(), strides.data(), element_sizes);
}

template<int ...Is>
auto OffsetCalculatorType_List_Impl(std::integer_sequence<int, Is...>) -> c10::variant<std::unique_ptr<OffsetCalculator<Is>>...>;

template<int N>
using OffsetCalculatorType_List = decltype(OffsetCalculatorType_List_Impl(std::make_integer_sequence<int, N>{}));


struct OffsetCalculatorVariant {
  using OffsetCalculatorTypes = OffsetCalculatorType_List<8>;

  OffsetCalculatorVariant(const TensorIteratorBase& iter) {
    int N = iter.ninputs();
    switch(N) {
#define DEFINE_CASE(index)        \
      case index : v = make_unique_input_offset_calculator<index>(iter); break;

      AT_FOR_8_INPUTS(DEFINE_CASE)
#undef DEFINE_CASE
      default:
        TORCH_CHECK(false, "OffsetCalculatorVariant not implemented for ninputs = ", N);
    }
  }

  void* data_ptr() {
    return c10::visit([](auto & v){ return static_cast<void*>(v.get()); }, v);
  }

 private:
  OffsetCalculatorTypes v;
};

template<int ...Is>
auto ArrayType_List_Impl(std::integer_sequence<int, Is...>) -> c10::variant<at::detail::Array<char*, Is + 2>...>;

template<int N>
using ArrayType_List = decltype(ArrayType_List_Impl(std::make_integer_sequence<int, N>{}));

struct ArrayVariant {
  // notice: This would produce c10::variant<at::detail::Array<char*, 2...10>>
  using ArrayTypes = ArrayType_List<8>;

  ArrayVariant(const TensorIteratorBase& iter) {
    int N = iter.ntensors();
    // jitted kernels must have at least 1 input and 1 output
    switch(N) {
#define DEFINE_CASE(index)      \
      case index + 2: array = at::detail::Array<char*, index + 2>{}; break;

      AT_FOR_8_INPUTS(DEFINE_CASE)
#undef DEFINE_CASE

      default:
        TORCH_CHECK(false, "ArrayVariant not implemented for ninputs = ", N);
    }

    c10::visit([&](auto& a) {
      for (auto i = 0; i < N; ++i) {
        a[i] = (char*)iter.data_ptr(i);
      }
    }, array);
  }

  void* data_ptr() {
    return c10::visit([](auto & a){ return static_cast<void*>(&a); }, array);
  }

private:
  ArrayTypes array;
};

template<int ...Is>
auto TrivialOffsetCalculator_List_Impl(std::integer_sequence<int, Is...>) -> c10::variant<TrivialOffsetCalculator<Is>...>;

template<int N>
using TrivialOffsetCalculator_List = decltype(TrivialOffsetCalculator_List_Impl(std::make_integer_sequence<int, N>{}));

struct TrivialOffsetCalculatorVariant {
  using TrivialOffsetCalculatorTypes = TrivialOffsetCalculator_List<8>;

  TrivialOffsetCalculatorVariant(int arity) {
    switch(arity) {
#define DEFINE_CASE(index)      \
      case index: v = TrivialOffsetCalculator<index>(); break;

      AT_FOR_8_INPUTS(DEFINE_CASE)
#undef DEFINE_CASE

      default:
        TORCH_CHECK(false, "TrivialOffsetCalculatorVariant not implemented for ninputs = ", arity);
    }
  }

  void* data_ptr() {
    return c10::visit([](auto & v){ return static_cast<void*>(&v); }, v);
  }

private:
  TrivialOffsetCalculatorTypes v;
};

template<int ...Is>
auto LoadWithCastPtr_List_Impl(std::integer_sequence<int, Is...>) -> c10::variant<std::unique_ptr<memory::LoadWithCast<Is>>...>;

template<int N>
using LoadWithCastPtr_List = decltype(LoadWithCastPtr_List_Impl(std::make_integer_sequence<int, N>{}));

struct LoadWithCastVariant {
  using LoadWithCastPtr = LoadWithCastPtr_List<8>;

  LoadWithCastVariant(const TensorIteratorBase& iter) {
    int arity = iter.ninputs();
    switch(arity) {
#define DEFINE_CASE(index)      \
      case index: v = std::make_unique<memory::LoadWithCast<index>>(iter); break;

      AT_FOR_8_INPUTS(DEFINE_CASE)
#undef DEFINE_CASE

      default:
        TORCH_CHECK(false, "make_input_offset_calculator not implemented for ninputs = ", arity);
    }
  }

  void* data_ptr() {
    return c10::visit([](auto & v){ return static_cast<void*>(v.get()); }, v);
  }

private:
  LoadWithCastPtr v;
};

static inline void launch_jitted_vectorized_kernel(
  const std::string& name, TensorIteratorBase& iter,
  DeviceIndex dev_idx, int64_t N, const std::string& f, void* data_ptr,
  const std::vector<at::Scalar>& extra_args) {
  TORCH_INTERNAL_ASSERT(N > 0 && N <= std::numeric_limits<int32_t>::max());
  // N is still int64_t for the computation, but it's always safe to cast result to int
  const uint32_t grid = (N + block_work_size() - 1) / block_work_size();

  // TODO: double check here, only seeing vec_size = 4, even for double
  const int vec_size = jitted_can_vectorize_up_to(iter);
  bool vectorized = vec_size > 1;

  // Different kernels are compiled depending on what we're vectorizing up to (1, 2 or 4 elements)
  //   fn_ptr is set to the appropriate function based on the vec size and GPU used
  // TODO: Memory use can probably be optimized by re-using kernels across GPUs with
  //   the same compute capability

  int nTensors =  iter.ntensors();
  const at::ScalarType common_dtype = iter.common_dtype();
  std::string f_inputs_type_str = at::cuda::jit::typeName(common_dtype);
  std::string compute_type_str = at::cuda::jit::typeName(toOpMathType(common_dtype));
  std::string result_type_str = at::cuda::jit::typeName(common_dtype);
  c10::SmallVector<std::string> extra_args_types = get_extra_args_typenames(extra_args);

  // The cache key includes all the parameters to generate_code + vec_size + dev_idx
  std::stringstream ss;
  ss << nTensors << f << name;
  ss << f_inputs_type_str << compute_type_str << result_type_str;
  ss << static_cast<int>(at::cuda::jit::BinaryFuncVariant::NoScalar);
  ss << extra_args_types;
  ss << vec_size;
// DeviceIndex, e.g. int8_t, is not treated as a number by the stream, cast to int as a workaround
  ss << static_cast<int>(dev_idx);
  const std::string cache_key = ss.str();

  static std::mutex _jiterator_mutex;
  static std::unordered_map<std::string, at::cuda::jit::NvrtcFunction> fns;
  at::cuda::jit::NvrtcFunction* fn_ptr = &fns[cache_key];

  if (!fn_ptr->function) {
    const std::lock_guard<std::mutex> lock{_jiterator_mutex};
    if (!fn_ptr->function) { // cache miss!
      // Generates program
      auto code = at::cuda::jit::generate_code(nTensors, f, name,
                                               f_inputs_type_str, compute_type_str, result_type_str,
                                               /*contiguous=*/true, /*dynamic_casting=*/false,
                                               at::cuda::jit::BinaryFuncVariant::NoScalar,
                                               extra_args_types,
                                               vectorized, vec_size);
      std::string kernel_name = vectorized ? name + "_vectorized" + std::to_string(vec_size) : name;

      // Acquires the program
      *fn_ptr = at::cuda::jit::jit_pwise_function(code, kernel_name);
    }
  }

  // size of `extra_args` is unknown at compile-time
  auto extra_args_size = extra_args.size();

  float scalar_val = 0;

  if (vectorized) {
    // pack args for kernel launch
    constexpr int kernel_args = 3;
    auto args = std::make_unique<void*[]>(kernel_args + extra_args_size);
    args[0] = static_cast<void*>(&N);
    args[1] = data_ptr;
    args[2] = static_cast<void*>(&scalar_val);

    for (const auto i : c10::irange(extra_args_size)) {
      // since 3 slots are already filled in `args`
      args[i + 3] = const_cast<void*>(extra_args[i].data_ptr());
    }
    at::cuda::jit::launch_jitted_pwise_function(*fn_ptr, args.get(), {grid, 1u, 1u}, {num_threads(), 1u, 1u});
  } else {
    TrivialOffsetCalculatorVariant input_offset_calculator(iter.ninputs());
    void* ic_ptr = input_offset_calculator.data_ptr();
    auto oc = TrivialOffsetCalculator<1>();
    auto l = memory::LoadWithoutCast();
    auto s = memory::StoreWithoutCast();

    // pack args for kernel launch
    constexpr int kernel_args = 7;
    auto args = std::make_unique<void*[]>(kernel_args + extra_args_size);
    args[0] = static_cast<void*>(&N);
    args[1] = data_ptr;
    args[2] = ic_ptr;
    args[3] = static_cast<void*>(&oc);
    args[4] = static_cast<void*>(&l);
    args[5] = static_cast<void*>(&s);
    args[6] = static_cast<void*>(&scalar_val);

    for (const auto i : c10::irange(extra_args_size)) {
      // since 7 slots are already filled in `args`
      args[i + 7] = const_cast<void*>(extra_args[i].data_ptr());
    }

    at::cuda::jit::launch_jitted_pwise_function(*fn_ptr, args.get(), {grid, 1u, 1u}, {num_threads(), 1u, 1u});
  }
}

static inline void launch_jitted_unrolled_kernel(
  const std::string& name, TensorIteratorBase& iter,
  DeviceIndex dev_idx, int64_t N, const std::string& f, void* data_ptr,
  void* ic_ptr, void* oc_ptr, void* l_ptr, void* s_ptr, bool contiguous, bool dynamic_casting,
  const std::vector<at::Scalar>& extra_args) {

  TORCH_INTERNAL_ASSERT(N > 0 && N <= std::numeric_limits<int32_t>::max());
  //casting result to int is always safe, intermediate is int64 and won't overflow
  const uint32_t grid = (N + block_work_size() - 1) / block_work_size();

  int nTensors = iter.ntensors();
  const at::ScalarType common_dtype = iter.common_dtype();
  std::string f_inputs_type_str = at::cuda::jit::typeName(common_dtype);
  std::string compute_type_str = at::cuda::jit::typeName(toOpMathType(common_dtype));
  std::string result_type_str = at::cuda::jit::typeName(common_dtype);
  c10::SmallVector<std::string> extra_args_types = get_extra_args_typenames(extra_args);

  // The cache key includes all the parameters to generate_code + dev_idx
  std::stringstream ss;
  ss << nTensors << f << name;
  ss << f_inputs_type_str << compute_type_str << result_type_str;
  ss << contiguous << dynamic_casting;
  ss << static_cast<int>(at::cuda::jit::BinaryFuncVariant::NoScalar);
  ss << extra_args_types;
  ss << dev_idx;
  const std::string cache_key = ss.str();

  static std::mutex _jiterator_mutex;
  static std::unordered_map<std::string, at::cuda::jit::NvrtcFunction> fns;

  at::cuda::jit::NvrtcFunction* fn_ptr = &fns[cache_key];
  if (!fn_ptr->function) {
    const std::lock_guard<std::mutex> lock{_jiterator_mutex};
    if (!fn_ptr->function) {
      auto code = at::cuda::jit::generate_code(nTensors, f, name,
                                               f_inputs_type_str, compute_type_str, result_type_str,
                                               contiguous, dynamic_casting,
                                               at::cuda::jit::BinaryFuncVariant::NoScalar,
                                               extra_args_types);
      *fn_ptr = at::cuda::jit::jit_pwise_function(code, name);
    }
  }

  float scalar_val = 0;

  // pack args for kernel launch
  constexpr int kernel_args = 7;
  auto extra_args_size = extra_args.size();
  auto args = std::make_unique<void*[]>(kernel_args + extra_args_size);
  args[0] = static_cast<void*>(&N);
  args[1] = data_ptr;
  args[2] = ic_ptr;
  args[3] = oc_ptr;
  args[4] = l_ptr;
  args[5] = s_ptr;
  args[6] = static_cast<void*>(&scalar_val);

  for (const auto i : c10::irange(extra_args_size)) {
    // since 7 slots are already filled in `args`
    args[i + 7] = const_cast<void*>(extra_args[i].data_ptr());
  }
  at::cuda::jit::launch_jitted_pwise_function(*fn_ptr, args.get(), {grid, 1u, 1u}, {num_threads(), 1u, 1u});
}

void jitted_gpu_kernel_dynamic_impl(
    const std::string& kernel_name,
    TensorIteratorBase& iter,
    const std::string& f,
    const bool dynamic_casting,
    const std::vector<at::Scalar>& extra_args) {

  TORCH_INTERNAL_ASSERT(iter.can_use_32bit_indexing());
  TORCH_INTERNAL_ASSERT(iter.noutputs() == 1);

  // TODO: assuming supported ninputs <=8, with only one output
  TORCH_INTERNAL_ASSERT(iter.ninputs() <= 8);

  ArrayVariant data(iter);
  void* data_ptr = data.data_ptr();

  int64_t numel = iter.numel();
  bool contiguous = iter.is_contiguous();

  // Decides which of 4 kernel types to launch
  // Variations are:
  //   - Case 1: no dynamic casting and contiguous
  //   - Case 2: no dynamic casting and noncontiguous
  //   - Case 3: dynamic casting and contiguous
  //   - Case 4: dynamic casting and noncontiguous
  // These cases align with the non-jitted CUDALoops.cuh cases in gpu_kernel_impl

  if (!dynamic_casting) {
    if (contiguous) {
      // Case 1: no dynamic casting and contiguous
      launch_jitted_vectorized_kernel(kernel_name, iter,
         iter.device().index(), numel, f, data_ptr, extra_args);
      return;
    }

    // Case 2: no dynamic casting and noncontiguous
    OffsetCalculatorVariant input_offset_calculator(iter);
    void* ic_ptr = input_offset_calculator.data_ptr();
    auto output_offset_calculator = make_output_offset_calculator(iter);
    void* oc_ptr = static_cast<void*>(&output_offset_calculator);

    auto loader = memory::LoadWithoutCast();
    auto storer = memory::StoreWithoutCast();
    void* l_ptr = static_cast<void*>(&loader);
    void* s_ptr = static_cast<void*>(&storer);

    launch_jitted_unrolled_kernel(
      kernel_name, iter, iter.device().index(), numel, f, data_ptr,
      ic_ptr, oc_ptr, l_ptr, s_ptr, contiguous, dynamic_casting, extra_args);

    return;
  }

  // Cases 3 and 4 are handled below
  // Both require construction of a storer (this asserts 1 output) and one or more loaders

  // Creates load casts from inputs (note offset indexing into the iterators 1...n tensors)
  LoadWithCastVariant loader(iter);
  void* l_ptr = loader.data_ptr();

  // Creates store cast to output (the zeroth tensor in TensorIterator)
  auto storer = memory::StoreWithCast(iter.dtype(0));
  void* s_ptr = static_cast<void*>(&storer);

  if (contiguous) {
    // Case 3: dynamic casting and contiguous
    TrivialOffsetCalculatorVariant input_offset_calculator(iter.ninputs());
    void* ic_ptr = input_offset_calculator.data_ptr();

    auto output_offset_calculator = TrivialOffsetCalculator<1>();
    void* oc_ptr = static_cast<void*>(&output_offset_calculator);

    launch_jitted_unrolled_kernel(
      kernel_name, iter, iter.device().index(), numel, f, data_ptr,
      ic_ptr, oc_ptr, l_ptr, s_ptr, contiguous, dynamic_casting, extra_args);
    return;
  }

  // Case 4: dynamic casting and noncontiguous
  OffsetCalculatorVariant input_offset_calculator(iter);
  void* ic_ptr = input_offset_calculator.data_ptr();

  auto output_offset_calculator = make_output_offset_calculator(iter);
  void* oc_ptr = static_cast<void*>(&output_offset_calculator);

  launch_jitted_unrolled_kernel(
      kernel_name, iter, iter.device().index(), numel, f, data_ptr,
      ic_ptr, oc_ptr, l_ptr, s_ptr, contiguous, dynamic_casting, extra_args);
}

void jitted_gpu_kernel_dynamic(
    const std::string& kernel_name,
    TensorIteratorBase& iter,
    const std::string& f,
    const std::vector<at::Scalar>& extra_args) {

  // TODO: much of preamble is common to both jitted_gpu_kernel and gpu_kernel
  //   Maybe it could be refactored?
  for (int arg = 0; arg < iter.ntensors(); arg++) {
    TORCH_INTERNAL_ASSERT(
      iter.device(arg).is_cuda(),
      "argument ", arg, ": expected a CUDA device but found ", iter.device(arg));
  }

  if (iter.numel() == 0) {
    return;
  }

  if (!iter.can_use_32bit_indexing()) {
    for (auto& sub_iter : iter.with_32bit_indexing()) {
      jitted_gpu_kernel_dynamic(kernel_name, sub_iter, f, extra_args);
    }
    return;
  }

  // Computes if dynamic casting is needed
  // Dynamic casting is needed if an input's or output's dtype differs from the common dtype
  // TODO: double check! this is different from jitted_gpu_kernel's logic
  bool needs_dynamic_casting = false;
  const at::ScalarType common_dtype = iter.common_dtype();
  for (auto i = 0; i < iter.ntensors(); ++i) {
    if (iter.dtype(i) != common_dtype) {
      needs_dynamic_casting = true;
      break;
    }
  }

  jitted_gpu_kernel_dynamic_impl(kernel_name, iter, f, needs_dynamic_casting, extra_args);
}

} // namespace native



namespace cuda {

at::Tensor CompileKernel(
  const std::string& op_string,
  const std::string& kernel_name,
  const std::vector<at::Tensor>& tensors,
  const std::vector<at::Scalar>& extra_args) {

  Tensor output;
  // TODO: double check if any other flags needs to be set
  TensorIteratorConfig config;
  config
    .set_check_mem_overlap(true)
    .allow_cpu_scalars(false)
    .promote_inputs_to_common_dtype(true)
    .cast_common_dtype_to_outputs(true)
    .enforce_safe_casting_to_output(true)
    .check_all_same_device(true)
    // TODO:  add_output or add_owned_output
    .add_owned_output(output);
  for (const auto& t: tensors){
    config.add_input(t);
  }
  TensorIterator iter = config.build();

  CUDAGuard guard(iter.device());
  at::native::jitted_gpu_kernel_dynamic(kernel_name, iter, op_string, extra_args);

  return iter.output();
}

}} // namespace at::cuda

#endif // AT_USE_JITERATOR()
