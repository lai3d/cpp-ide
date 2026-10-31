#include "greeter.h"

#include <cctype>
#include <numeric>

namespace hello {

Greeter::Greeter(std::string greeting) : greeting_(std::move(greeting)) {}

std::string Greeter::greet(const std::string &name) const {
    return greeting_ + ", " + name + "!";
}

std::string Greeter::shout(const std::string &name) const {
    std::string text = greet(name);
    for (auto &c : text) {
        c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    }
    return text;
}

int sum(const std::vector<int> &values) {
    return std::accumulate(values.begin(), values.end(), 0);
}

} // namespace hello
