// Disable LeakSanitizer at build time (ASan + UBSan stay fully active). Mayhem traces the process
// for edge coverage, and LSan's exit-time ptrace-attach fails under that trace, aborting the run
// before Mayhem records any edges. This is the sanctioned build-time hook; Mayhem alone owns the
// runtime sanitizer option set.
extern "C" int __lsan_is_turned_off() { return 1; }
