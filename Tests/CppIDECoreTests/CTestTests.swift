import Foundation
import Testing
@testable import CppIDECore

@Suite struct CTestReportTests {
    static let output = """
        Test project /p/build
            Start 1: greeting
        1/5 Test #1: greeting .........................   Passed    0.01 sec
            Start 2: Greeter.Shout
        2/5 Test #2: Greeter.Shout ....................***Failed    0.02 sec
        /p/tests/greeter_test.cpp:12: Failure
        Expected equality of these values:
            Start 3: crash
        3/5 Test #3: crash ............................***Exception: SegFault  0.10 sec
            Start 4: disabled_case
        4/5 Test #4: disabled_case ....................***Not Run (Disabled)   0.00 sec
            Start 5: slow
        5/5 Test #5: slow .............................***Timeout   1.50 sec

        20% tests passed, 3 tests failed out of 5

        Total Test time (real) =   1.65 sec

        The following tests FAILED:
        \t  2 - Greeter.Shout (Failed)
        """

    @Test func parsesStatusesTimesAndFailureOutput() {
        var report = TestReport()
        for line in Self.output.split(separator: "\n", omittingEmptySubsequences: false) { report.consume(line: String(line)) }
        #expect(report.tests.map(\.name) == ["greeting", "Greeter.Shout", "crash", "disabled_case", "slow"])
        #expect(report.tests.map(\.status) == [.passed, .failed, .failed, .skipped, .failed])
        #expect(report.passed == 1 && report.failed == 3 && report.skipped == 1)
        #expect(report.tests[0].elapsed == 0.01)
        #expect(report.tests[1].output.contains("greeter_test.cpp:12: Failure"))
        #expect(report.tests[1].output.contains("Expected equality"))
        #expect(report.tests[2].detail?.contains("SegFault") == true)
        #expect(report.tests[4].detail == "Timeout")
        #expect(report.tests[0].output.isEmpty)
        #expect(report.anyPackageFailed && report.packages.first?.status == .failed)
        #expect(!report.buildOutput.contains("Total Test time"))
    }

    @Test func runningUntilResultAndNoTestsMessage() {
        var report = TestReport()
        report.consume(line: "    Start 1: only")
        #expect(report.tests.first?.status == .running)
        var empty = TestReport()
        empty.consume(line: "No tests were found!!!")
        #expect(empty.tests.isEmpty && empty.buildOutput.contains("No tests were found"))
    }
}

@Suite struct TestFinderTests {
    static let source = """
        #include <gtest/gtest.h>

        TEST(Math, Adds) {
            EXPECT_EQ(1 + 1, 2);
        }

        TEST_F(GreeterTest, Shouts) {
            EXPECT_TRUE(true);
        }

        TEST_CASE("vectors can be sized", "[vector]") {
            REQUIRE(true);
        }
        """

    @Test func findsGoogleTestAndCatchTests() {
        let tests = TestFinder.testFunctions(in: Self.source)
        #expect(tests.map(\.name) == ["Math.Adds", "GreeterTest.Shouts", "vectors can be sized"])
        #expect(tests.map(\.line) == [2, 6, 10])
    }

    @Test func findsEnclosingTest() {
        let ns = Self.source as NSString
        let inside = ns.range(of: "EXPECT_TRUE").location
        #expect(TestFinder.enclosingTest(in: Self.source, at: inside) == "GreeterTest.Shouts")
        #expect(TestFinder.enclosingTest(in: Self.source, at: 0) == nil)
        #expect(TestFinder.enclosingTest(in: Self.source, at: ns.range(of: "REQUIRE").location) == "vectors can be sized")
    }

    @Test func detectsTestFiles() {
        #expect(TestFinder.isTestFile(name: "greeter_test.cpp", text: ""))
        #expect(TestFinder.isTestFile(name: "math.cpp", text: Self.source))
        #expect(!TestFinder.isTestFile(name: "main.cpp", text: "int main() {}"))
    }

    @Test func findsFileReferences() {
        let refs = TestFinder.fileReferences(in: "src/a.cpp:12:5: error: expected ';'")
        #expect(refs.count == 1 && refs[0].file == "src/a.cpp" && refs[0].line == 12)
        #expect(TestFinder.fileReferences(in: "/p/include/x.hpp:3: note")[0].file == "/p/include/x.hpp")
        #expect(TestFinder.fileReferences(in: "no refs: main.go:3").isEmpty)
    }

    @Test func buildsAnchoredCTestFilters() {
        #expect(TestFinder.ctestFilter("Math.Adds") == "^Math\\.Adds$")
    }
}
