#pragma once
#include "runtime/context.h"
#include <sys/resource.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach/mach.h>
#else
#include <fstream>
#endif
namespace sputnik::notebook::worker {
class ProcessTelemetry {
public:
  void sample(runtime::RuntimeRunTelemetry &out, std::uint64_t now) {
    out.sampled_ms = now;
    struct rusage usage{};
    if (::getrusage(RUSAGE_SELF, &usage) == 0) {
      const double cpu = usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 + usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
      if (previous_ms_ && now > previous_ms_) out.cpu_percent = std::max(0.0, (cpu - previous_cpu_) * 100000 / double(now - previous_ms_));
      previous_ms_ = now; previous_cpu_ = cpu;
    }
#ifdef __APPLE__
    mach_task_basic_info_data_t info{}; mach_msg_type_number_t size = MACH_TASK_BASIC_INFO_COUNT;
    if (::task_info(mach_task_self(), MACH_TASK_BASIC_INFO, reinterpret_cast<task_info_t>(&info), &size) == KERN_SUCCESS)
      out.resident_bytes = info.resident_size;
#else
    std::ifstream file("/proc/self/statm"); std::uint64_t pages, resident;
    if (file >> pages >> resident) { const auto page = ::sysconf(_SC_PAGESIZE); if (page > 0) out.resident_bytes = resident * std::uint64_t(page); }
#endif
  }
private:
  double previous_cpu_ = 0;
  std::uint64_t previous_ms_ = 0;
};
}
