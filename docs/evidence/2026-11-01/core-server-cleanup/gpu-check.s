package maintenance.core_cleanup_gpu

from slowpilot.torch.tensor.factories import tensor
from slowpilot.torch.backends import cuda_available?, cuda_device_count

export main

def main():
  parser = ArgParser()
  parser.arg("--gpus", type: Int, required: true)
  args = parser.parse_or_raise
  raise ValueError("GPU unavailable") unless cuda_available?
  raise ValueError("unexpected visible GPU count") unless cuda_device_count == args[:gpus]
  cuda_device_count.times |i|:
    x = tensor([1.0, 2.0, 3.0], device: "cuda:" + i.to_str, requires_grad: true)
    loss = x.square.sum
    loss.backward!
    raise ValueError("forward result") unless loss.item == 14.0
    raise ValueError("backward result") unless x.grad.to_a == [2.0, 4.0, 6.0]
  print "PASS_GPU_AFTER_HOST_CLEANUP devices=" + args[:gpus].to_str
  0
