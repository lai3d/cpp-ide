#include <cstdio>
#include <cstring>

#include "greeter.h"

// A tiny test runner: ctest runs `greeter_test <case>`; a non-zero exit fails the test.
static int check(bool ok, const char *what) {
    if (!ok) std::fprintf(stderr, "FAILED: %s\n", what);
    return ok ? 0 : 1;
}

int main(int argc, char *argv[]) {
    hello::Greeter greeter;
    const char *which = argc > 1 ? argv[1] : "";
    if (std::strcmp(which, "greeting") == 0) return check(greeter.greet("Ada") == "Hello, Ada!", "greet");
    if (std::strcmp(which, "shout") == 0) return check(greeter.shout("Ada") == "HELLO, ADA!", "shout");
    std::fprintf(stderr, "unknown case: %s\n", which);
    return 2;
}
