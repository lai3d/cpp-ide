#include <iostream>
#include <string>
#include <vector>

#include "greeter.h"

int main(int argc, char *argv[]) {
    std::string name = argc > 1 ? argv[1] : "world";
    hello::Greeter greeter;
    std::cout << greeter.greet(name) << '\n';

    std::vector<int> numbers{1, 2, 3, 4};
    int total = hello::sum(numbers);
    std::cout << "sum = " << total << '\n';
    return 0;
}
