// Disables LeakSanitizer preventively (SPEC.md §6.2 item 15): -fsanitize=address always bundles
// LSan in, and leaks aren't the class this fleet fuzzes for. ASan and UBSan stay fully active.
extern "C" int __lsan_is_turned_off() {
    return 1;
}
