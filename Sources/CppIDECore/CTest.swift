import Foundation

public struct TestResult: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable { case running, passed, failed, skipped }

    /// The test runner / suite this came from ("ctest").
    public let package: String
    /// Test name as ctest knows it (`Suite.Name` for GoogleTest, the TEST_CASE string for Catch2).
    public let name: String?
    public var status: Status
    public var elapsed: Double?
    public var output: String
    /// ctest's failure detail, e.g. "Exception: SegFault" or "Timeout".
    public var detail: String?

    public var id: String { package + "|" + (name ?? "") }
    public var depth: Int { 0 }
    public var shortName: String { name ?? package }
}

/// Aggregates streamed `ctest --output-on-failure` output into per-test results.
public struct TestReport: Sendable {
    public private(set) var tests: [TestResult] = []
    public private(set) var packages: [TestResult] = []
    /// Lines that don't belong to a test (configure/build errors, "No tests were found", …).
    public private(set) var buildOutput = ""
    private var index: [String: Int] = [:]
    /// The test whose --output-on-failure block we're inside.
    private var outputOwner: Int?
    /// `ctest -V` output per test number ("3: …" lines), attached to the test when it fails.
    private var verboseOutput: [Int: String] = [:]
    /// Results of individual test functions reported inside a ctest test's output: Unity
    /// (`file.c:12:test_add:PASS`), CMocka and GoogleTest (`[       OK ] name`).
    public private(set) var functionStatuses: [String: TestResult.Status] = [:]

    public init() {}

    public var passed: Int { tests.filter { $0.status == .passed }.count }
    public var failed: Int { tests.filter { $0.status == .failed }.count }
    public var skipped: Int { tests.filter { $0.status == .skipped }.count }
    public var anyPackageFailed: Bool { failed > 0 }

    //     Start  3: Greeter.Hello
    private static let start = try! NSRegularExpression(pattern: #"^\s*Start\s+\d+:\s+(.+?)\s*$"#)
    // 3/4 Test  #3: Greeter.Hello ....................***Failed    0.01 sec
    private static let result = try! NSRegularExpression(
        pattern: #"^\s*\d+/\d+\s+Test\s+#(\d+):\s+(.+?)\s+\.+\s*(\*{0,3})\s*(Passed|Failed|Not Run|Skipped|Exception|Timeout|\S+)(.*?)\s+([\d.]+)\s+sec\s*$"#)
    // 3: tests/test_math.c:12:test_add:PASS   (ctest -V prefixes a test's output with its number)
    private static let numbered = try! NSRegularExpression(pattern: #"^(\d+): ?(.*)$"#)
    // Unity: tests/test_math.c:12:test_add:FAIL: Expected 3 Was 4
    private static let unity = try! NSRegularExpression(pattern: #"^\S.*?:\d+:([A-Za-z_]\w*):(PASS|FAIL|IGNORE)\b"#)
    // CMocka / GoogleTest: [       OK ] test_add   [  FAILED  ] Suite.Name (0 ms)
    private static let bracketed = try! NSRegularExpression(
        pattern: #"^\[\s*(RUN|OK|FAILED|SKIPPED|ERROR)\s*\]\s+([A-Za-z_][\w.]*)(?:\s+\(.*\))?\s*$"#)
    /// ctest -V chatter that isn't test output.
    private static let verboseNoise = ["UpdateCTestConfiguration", "Constructing a list of tests", "Done constructing a list",
                                       "Updating test list for fixtures", "Checking test dependency graph",
                                       "Test command:", "Working Directory:", "Test timeout computed", "Environment variables:"]

    public mutating func consume(line: String) {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let match = Self.numbered.firstMatch(in: line, range: range),
           let number = Int(ns.substring(with: match.range(at: 1))) {
            let text = ns.substring(with: match.range(at: 2))
            guard !Self.verboseNoise.contains(where: text.hasPrefix) else { return }
            recordFunctionResult(text)
            verboseOutput[number, default: ""] += text + "\n"
            return
        }
        if Self.verboseNoise.contains(where: line.hasPrefix)
            || line.range(of: #"^(test \d+|Added \d+ tests? to meet fixture requirements|\s+\d+ - .+ \(.+\))$"#,
                          options: .regularExpression) != nil {
            return
        }
        if let match = Self.start.firstMatch(in: line, range: range) {
            let i = slot(for: ns.substring(with: match.range(at: 1)))
            tests[i].status = .running
            outputOwner = nil
            return
        }
        if let match = Self.result.firstMatch(in: line, range: range) {
            let number = Int(ns.substring(with: match.range(at: 1))) ?? -1
            let name = ns.substring(with: match.range(at: 2))
            let word = ns.substring(with: match.range(at: 4))
            let rest = ns.substring(with: match.range(at: 5)).trimmingCharacters(in: .whitespaces)
            let i = slot(for: name)
            tests[i].elapsed = Double(ns.substring(with: match.range(at: 6)))
            switch word {
            case "Passed": tests[i].status = .passed
            case "Skipped": tests[i].status = .skipped
            case "Not Run" where rest.contains("Disabled"): tests[i].status = .skipped
            default:
                tests[i].status = .failed
                let detail = (word + " " + rest.trimmingCharacters(in: CharacterSet(charactersIn: ": ")))
                    .trimmingCharacters(in: .whitespaces)
                tests[i].detail = detail == "Failed" ? nil : detail
            }
            outputOwner = tests[i].status == .failed ? i : nil
            if let verbose = verboseOutput.removeValue(forKey: number), tests[i].status == .failed {
                tests[i].output += verbose
            }
            updateSummary()
            return
        }
        if line.range(of: #"^\d+% tests passed"#, options: .regularExpression) != nil
            || line.hasPrefix("The following tests FAILED") || line.hasPrefix("Total Test time") {
            outputOwner = nil
            return
        }
        if let owner = outputOwner {
            recordFunctionResult(line)
            tests[owner].output += line + "\n"
        } else if !line.isEmpty, !line.hasPrefix("Test project ") {
            buildOutput += line + "\n"
        }
    }

    private mutating func recordFunctionResult(_ text: String) {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let name: String, word: String
        if let match = Self.unity.firstMatch(in: text, range: range) {
            (name, word) = (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
        } else if let match = Self.bracketed.firstMatch(in: text, range: range) {
            (name, word) = (ns.substring(with: match.range(at: 2)), ns.substring(with: match.range(at: 1)))
        } else {
            return
        }
        switch word {
        case "RUN": functionStatuses[name] = .running
        case "PASS", "OK": functionStatuses[name] = .passed
        case "IGNORE", "SKIPPED": functionStatuses[name] = .skipped
        default: functionStatuses[name] = .failed
        }
    }

    private mutating func slot(for name: String) -> Int {
        if let existing = index[name] { return existing }
        tests.append(TestResult(package: "ctest", name: name, status: .running, elapsed: nil, output: ""))
        index[name] = tests.count - 1
        updateSummary()
        return tests.count - 1
    }

    private mutating func updateSummary() {
        let status: TestResult.Status = tests.contains { $0.status == .failed } ? .failed
            : tests.contains { $0.status == .running } ? .running : .passed
        packages = [TestResult(package: "ctest", name: nil, status: status,
                               elapsed: tests.compactMap(\.elapsed).reduce(0, +), output: "")]
    }
}

/// Finds GoogleTest / Catch2 / doctest / Unity / CMocka test declarations in source text.
public enum TestFinder {
    /// C test frameworks whose tests are functions inside one ctest test (not discovered per test).
    public enum CFramework: Sendable { case unity, cmocka }

    public static func cFramework(in text: String) -> CFramework? {
        if text.range(of: #"#\s*include\s*[<"]unity\.h[>"]"#, options: .regularExpression) != nil { return .unity }
        if text.range(of: #"#\s*include\s*[<"]cmocka\.h[>"]"#, options: .regularExpression) != nil { return .cmocka }
        return nil
    }

    // Unity: void test_add(void) {     RUN_TEST(test_add);
    private static let unityFunction = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:static\s+)?void\s+([A-Za-z_]\w*)\s*\(\s*void\s*\)\s*(?:\{|$)"#, options: .anchorsMatchLines)
    private static let unityRun = try! NSRegularExpression(pattern: #"\bRUN_TEST\s*\(\s*([A-Za-z_]\w*)"#)
    // CMocka: static void test_add(void **state) {     cmocka_unit_test(test_add),
    private static let cmockaFunction = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:static\s+)?void\s+([A-Za-z_]\w*)\s*\(\s*void\s*\*\s*\*\s*\w*\s*\)\s*(?:\{|$)"#,
        options: .anchorsMatchLines)
    private static let cmockaRun = try! NSRegularExpression(pattern: #"\bcmocka_unit_test\w*\s*\(\s*([A-Za-z_]\w*)"#)

    /// Unity / CMocka test functions: those registered with RUN_TEST / cmocka_unit_test when the file
    /// does so, otherwise the ones named `test…`.
    private static func cTestFunctions(in text: String, framework: CFramework) -> [(name: String, offset: Int)] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let (definition, registration) = framework == .unity ? (unityFunction, unityRun) : (cmockaFunction, cmockaRun)
        let registered = Set(registration.matches(in: text, range: range).map { ns.substring(with: $0.range(at: 1)) })
        return definition.matches(in: text, range: range).compactMap { match in
            let name = ns.substring(with: match.range(at: 1))
            let isTest = registered.isEmpty ? name.lowercased().hasPrefix("test") : registered.contains(name)
            return isTest ? (name, match.range.location) : nil
        }
    }

    // TEST(Suite, Name)  TEST_F(Fixture, Name)  TYPED_TEST(Suite, Name)
    private static let gtest = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:TEST|TEST_F|TYPED_TEST|FRIEND_TEST)\s*\(\s*(\w+)\s*,\s*(\w+)\s*\)"#, options: .anchorsMatchLines)
    // TEST_CASE("name", "[tag]")  SCENARIO("name")  TEST_CASE_METHOD(Fixture, "name")
    private static let catchCase = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:TEST_CASE|SCENARIO|TEST_CASE_METHOD\s*\(\s*\w+\s*,)\s*\(?\s*"((?:\\.|[^"\\])*)""#,
        options: .anchorsMatchLines)

    /// Tests with their zero-based declaration lines, named the way ctest's discovery names them
    /// (`Suite.Name` for GoogleTest, the TEST_CASE string for Catch2/doctest), or by function
    /// name for Unity / CMocka.
    public static func testFunctions(in text: String) -> [(name: String, line: Int)] {
        let ns = text as NSString
        let index = LineIndex(text)
        let range = NSRange(location: 0, length: ns.length)
        var found: [(name: String, line: Int, offset: Int)] = []
        for match in gtest.matches(in: text, range: range) {
            let name = ns.substring(with: match.range(at: 1)) + "." + ns.substring(with: match.range(at: 2))
            found.append((name, index.position(of: match.range.location).line, match.range.location))
        }
        for match in catchCase.matches(in: text, range: range) {
            let name = ns.substring(with: match.range(at: 1))
            found.append((name, index.position(of: match.range.location).line, match.range.location))
        }
        if let framework = cFramework(in: text) {
            for test in cTestFunctions(in: text, framework: framework) {
                found.append((test.name, index.position(of: test.offset).line, test.offset))
            }
        }
        return found.sorted { $0.offset < $1.offset }.map { ($0.name, $0.line) }
    }

    /// The test whose declaration is the nearest one at or above `offset`.
    public static func enclosingTest(in text: String, at offset: Int) -> String? {
        let caretLine = LineIndex(text).position(of: offset).line
        return testFunctions(in: text).last { $0.line <= caretLine }?.name
    }

    /// True for files that look like test sources (by name or content).
    public static func isTestFile(name: String, text: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains("test") || lower.contains("spec") { return true }
        return !testFunctions(in: text).isEmpty
    }

    private static let referencePattern = try! NSRegularExpression(
        pattern: #"([\w./+\-]+\.(?:c|cc|cpp|cxx|c\+\+|h|hh|hpp|hxx|inl|ipp|m|mm)):(\d+)"#)

    /// `file.cpp:12` (and `file.cpp:12:5`) references in compiler/test output, with their ranges in `line`.
    public static func fileReferences(in line: String) -> [(range: NSRange, file: String, line: Int)] {
        let ns = line as NSString
        return referencePattern.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let number = Int(ns.substring(with: match.range(at: 2))) else { return nil }
            return (match.range, ns.substring(with: match.range(at: 1)), number)
        }
    }

    /// An anchored ctest `-R` regex matching exactly `name`.
    /// Quick pre-filter before parsing a file for tests.
    public static func mightContainTests(_ text: String) -> Bool {
        text.contains("TEST") || text.contains("SCENARIO") || text.contains("unity.h") || text.contains("cmocka.h")
    }

    public static func ctestFilter(_ name: String) -> String {
        "^" + NSRegularExpression.escapedPattern(for: name) + "$"
    }
}
