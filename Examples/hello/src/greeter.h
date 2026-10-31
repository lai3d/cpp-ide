#pragma once

#include <string>
#include <vector>

namespace hello {

/// Builds friendly messages.
class Greeter {
public:
    explicit Greeter(std::string greeting = "Hello");

    std::string greet(const std::string &name) const;
    std::string shout(const std::string &name) const;

private:
    std::string greeting_;
};

int sum(const std::vector<int> &values);

} // namespace hello
