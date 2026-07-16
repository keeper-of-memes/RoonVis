#include "TestHarness.h"

#include "LegacyNameMigration.h"

#include <map>
#include <set>
#include <string>

using namespace RoonVis;

namespace
{

void TestParseWellFormedMap()
{
    const std::string json =
        "{\n"
        " \"Old_-_Name.milk\": \"Old - Name.milk\",\n"
        " \"Other_Preset.milk\" :\t\"Author - Other Preset.milk\" ,\n"
        " \"Escaped\\\"Quote.milk\": \"Escaped \\\\ Slash.milk\"\n"
        "}\n";
    std::map<std::string, std::string> map = ParseLegacyNameMapJSON(json);
    REQUIRE(map.size() == 3);
    CHECK(map["Old_-_Name.milk"] == "Old - Name.milk");
    CHECK(map["Other_Preset.milk"] == "Author - Other Preset.milk");
    CHECK(map["Escaped\"Quote.milk"] == "Escaped \\ Slash.milk");
}

void TestParseEmptyAndGarbage()
{
    CHECK(ParseLegacyNameMapJSON("").empty());
    CHECK(ParseLegacyNameMapJSON("{}").empty());
    CHECK(ParseLegacyNameMapJSON("  { }  ").empty());
    CHECK(ParseLegacyNameMapJSON("not json at all").empty());
    CHECK(ParseLegacyNameMapJSON("[\"a\", \"b\"]").empty());
    CHECK(ParseLegacyNameMapJSON("{\"a\": 1}").empty());
    CHECK(ParseLegacyNameMapJSON("{\"a\": \"b\"").empty());
    CHECK(ParseLegacyNameMapJSON("{\"a\": \"b\",}").empty());
    CHECK(ParseLegacyNameMapJSON("{\"a\": \"b\"} trailing").empty());
    // All-or-nothing: one malformed entry poisons the whole map.
    CHECK(ParseLegacyNameMapJSON("{\"a\": \"b\", \"c\": 3}").empty());
    // Empty keys are skipped; empty values are kept (drop directives).
    std::map<std::string, std::string> map =
        ParseLegacyNameMapJSON("{\"\": \"x.milk\", \"gone.milk\": \"\"}");
    REQUIRE(map.size() == 1);
    CHECK(map.count("") == 0);
    CHECK(map["gone.milk"] == "");
}

void TestMigrateNameSet()
{
    const std::map<std::string, std::string> nameMap = {
        {"old_a.milk", "New A.milk"},
        {"old_b.milk", "New B.milk"},
        {"gone.milk", ""},  // explicit drop directive
    };

    // Mapped, dropped, and pass-through in one input.
    std::set<std::string> names = {
        "old_a.milk",       // mapped
        "gone.milk",        // dropped
        "New CotC.milk",    // pass-through (trial-build favourite, not a map key)
    };
    MigratedNameSet result = MigrateNameSet(names, nameMap);
    CHECK(result.mappedCount == 1);
    CHECK(result.droppedCount == 1);
    REQUIRE(result.names.size() == 2);
    CHECK(result.names.count("New A.milk") == 1);
    CHECK(result.names.count("New CotC.milk") == 1);
    CHECK(result.names.count("old_a.milk") == 0);
    CHECK(result.names.count("gone.milk") == 0);

    // Empty input.
    MigratedNameSet empty = MigrateNameSet({}, nameMap);
    CHECK(empty.names.empty());
    CHECK(empty.mappedCount == 0);
    CHECK(empty.droppedCount == 0);

    // Empty map: everything passes through untouched.
    MigratedNameSet untouched = MigrateNameSet(names, {});
    CHECK(untouched.names == names);
    CHECK(untouched.mappedCount == 0);
    CHECK(untouched.droppedCount == 0);

    // Mapped name colliding with an already-present new name dedupes in the set.
    std::set<std::string> colliding = {"old_a.milk", "New A.milk"};
    MigratedNameSet deduped = MigrateNameSet(colliding, nameMap);
    CHECK(deduped.mappedCount == 1);
    CHECK(deduped.droppedCount == 0);
    REQUIRE(deduped.names.size() == 1);
    CHECK(deduped.names.count("New A.milk") == 1);
}

void TestMigrateNameCounts()
{
    const std::map<std::string, std::string> nameMap = {
        {"old_a.milk", "New A.milk"},
        {"old_a2.milk", "New A.milk"},  // maps onto the same target as old_a
        {"gone.milk", ""},
    };

    std::map<std::string, int> counts = {
        {"old_a.milk", 1},
        {"gone.milk", 5},
        {"keep.milk", 2},  // pass-through
    };
    MigratedNameCounts result = MigrateNameCounts(counts, nameMap);
    CHECK(result.mappedCount == 1);
    CHECK(result.droppedCount == 1);
    REQUIRE(result.counts.size() == 2);
    CHECK(result.counts.at("New A.milk") == 1);
    CHECK(result.counts.at("keep.milk") == 2);

    // Collision after mapping keeps the MAX count (both directions).
    std::map<std::string, int> collideMappedHigher = {
        {"old_a.milk", 3},
        {"old_a2.milk", 1},
    };
    MigratedNameCounts maxA = MigrateNameCounts(collideMappedHigher, nameMap);
    CHECK(maxA.mappedCount == 2);
    REQUIRE(maxA.counts.size() == 1);
    CHECK(maxA.counts.at("New A.milk") == 3);

    std::map<std::string, int> collideOtherHigher = {
        {"old_a.milk", 1},
        {"old_a2.milk", 4},
    };
    MigratedNameCounts maxB = MigrateNameCounts(collideOtherHigher, nameMap);
    REQUIRE(maxB.counts.size() == 1);
    CHECK(maxB.counts.at("New A.milk") == 4);

    // Mapped entry colliding with a pass-through entry on the same name.
    std::map<std::string, int> collidePassThrough = {
        {"old_a.milk", 2},
        {"New A.milk", 7},
    };
    MigratedNameCounts maxC = MigrateNameCounts(collidePassThrough, nameMap);
    REQUIRE(maxC.counts.size() == 1);
    CHECK(maxC.counts.at("New A.milk") == 7);
}

}  // namespace

void RunLegacyNameMigrationTests()
{
    TestParseWellFormedMap();
    TestParseEmptyAndGarbage();
    TestMigrateNameSet();
    TestMigrateNameCounts();
}
