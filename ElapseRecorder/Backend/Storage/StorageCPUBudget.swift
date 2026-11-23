import Darwin

/// Limits background storage work to one eighth of a core, leaving headroom for capture.
/// Count the whole process: framework helper threads do much of the codec work. Time already
/// spent waiting on disk or hardware counts toward the interval; no delay is added when I/O-bound.
nonisolated struct StorageCPUBudget {
    private var cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
    private var wallStart = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)

    mutating func pace() async throws {
        let cpu = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStart
        let elapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - wallStart
        let interval = cpu * 8
        if interval > elapsed {
            try await Task.sleep(nanoseconds: interval - elapsed)
        }
        cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        wallStart = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }
}
