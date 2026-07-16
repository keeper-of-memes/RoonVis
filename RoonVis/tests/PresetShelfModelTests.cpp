#include "TestHarness.h"

#include "PresetShelfModel.h"

#include <set>
#include <string>
#include <vector>

using namespace RoonVis;

namespace
{

PresetShelfInput Preset(size_t index, const char *filename, const char *title, bool favorite = false)
{
    PresetShelfInput input;
    input.index = index;
    input.filename = filename;
    input.title = title;
    input.favorite = favorite;
    return input;
}

void TestAuthorClusterExtraction()
{
    CHECK(PresetAuthorClusterTitle("suksma_-_Aural.milk") == "suksma");
    CHECK(PresetAuthorClusterTitle("LuxXx-Foo.milk") == "LuxXx");
    CHECK(PresetAuthorClusterTitle("TonyMilkdrop_bar.milk") == "TonyMilkdrop");
    CHECK(PresetAuthorClusterTitle("  Geiss  - spark.milk") == "Geiss");
}

void TestShelvesFoldSmallClustersIntoOther()
{
    std::vector<PresetShelfInput> presets = {
        Preset(0, "Beta_-_Second.milk", "B Second"),
        Preset(1, "alpha_-_Third.milk", "A Third", true),
        Preset(2, "alpha_-_First.milk", "A First"),
        Preset(3, "Tiny_-_Only.milk", "Tiny Only"),
        Preset(4, "ALPHA_-_Second.milk", "A Second"),
        Preset(5, "Beta_-_First.milk", "B First", true),
        Preset(6, "Beta_-_Third.milk", "B Third"),
    };

    std::vector<PresetShelf> shelves = BuildPresetShelves(presets, false, 3);
    // The Presets tab has NO Favorites shelf — favourites live in their artist clusters
    // like any other preset. alpha {2,4,1} and Beta {5,0,6} each reach the minimum cluster
    // size of 3; Tiny {3} folds into "Other". Clusters iterate in normalized-key order.
    REQUIRE(shelves.size() == 3);
    CHECK(shelves[0].title == "alpha");
    CHECK((shelves[0].indexes == std::vector<size_t>{2, 4, 1}));
    CHECK(shelves[1].title == "Beta");
    CHECK((shelves[1].indexes == std::vector<size_t>{5, 0, 6}));
    CHECK(shelves[2].title == "Other");
    CHECK((shelves[2].indexes == std::vector<size_t>{3}));
}

void TestFavoritesNotDuplicatedAcrossShelves()
{
    std::vector<PresetShelfInput> presets = {
        Preset(0, "alpha_-_A.milk", "alpha A"),
        Preset(1, "alpha_-_B.milk", "alpha B", true),
        Preset(2, "alpha_-_C.milk", "alpha C"),
        Preset(3, "alpha_-_D.milk", "alpha D"),
        Preset(4, "Beta_-_A.milk", "Beta A", true),
        Preset(5, "Beta_-_B.milk", "Beta B"),
        Preset(6, "Beta_-_C.milk", "Beta C"),
        Preset(7, "Beta_-_D.milk", "Beta D"),
    };

    std::vector<PresetShelf> shelves = BuildPresetShelves(presets, false, 3);

    // No preset index appears in more than one shelf — a duplicate index in the displayed
    // grid is undefined behavior for SwiftUI's ForEach(id: \.self)/.focused(equals:) and
    // was breaking focus/scroll to the current preset when a favourite was playing. The
    // Presets tab now has NO Favorites shelf, so favourites can't collide with a cluster.
    std::set<size_t> seen;
    bool noDuplicates = true;
    bool sawFavoritesShelf = false;
    for (const PresetShelf &shelf : shelves)
    {
        if (shelf.title == "Favorites")
        {
            sawFavoritesShelf = true;
        }
        for (size_t idx : shelf.indexes)
        {
            if (!seen.insert(idx).second)
            {
                noDuplicates = false;
            }
        }
    }
    CHECK(noDuplicates);
    CHECK(!sawFavoritesShelf);

    // Favourites appear in their artist clusters exactly like any other preset.
    REQUIRE(shelves.size() == 2);
    CHECK(shelves[0].title == "alpha");
    CHECK((shelves[0].indexes == std::vector<size_t>{0, 1, 2, 3}));
    CHECK(shelves[1].title == "Beta");
    CHECK((shelves[1].indexes == std::vector<size_t>{4, 5, 6, 7}));
}

void TestFavoritesOnlyKeepsSegmentBehavior()
{
    std::vector<PresetShelfInput> presets = {
        Preset(0, "Alpha_-_One.milk", "Alpha One"),
        Preset(1, "Beta_-_One.milk", "Beta One", true),
        Preset(2, "Gamma_-_One.milk", "Gamma One", true),
    };

    std::vector<PresetShelf> shelves = BuildPresetShelves(presets, true, 3);
    REQUIRE(shelves.size() == 1);
    CHECK(shelves[0].title == "Favorites");
    CHECK((shelves[0].indexes == std::vector<size_t>{1, 2}));

    shelves = BuildPresetShelves(std::vector<PresetShelfInput>{Preset(0, "Alpha_-_One.milk", "Alpha One")}, true, 3);
    CHECK(shelves.empty());
}

void TestFlattenPresetShelfIndexesFollowsBrowseOrderWithoutDuplicates()
{
    std::vector<PresetShelfInput> presets = {
        Preset(0, "Beta_-_Second.milk", "B Second"),
        Preset(1, "alpha_-_Third.milk", "A Third", true),
        Preset(2, "alpha_-_First.milk", "A First"),
        Preset(3, "Tiny_-_Only.milk", "Tiny Only"),
        Preset(4, "ALPHA_-_Second.milk", "A Second"),
        Preset(5, "Beta_-_First.milk", "B First", true),
        Preset(6, "Beta_-_Third.milk", "B Third"),
    };

    std::vector<PresetShelf> shelves = BuildPresetShelves(presets, false, 3);
    CHECK((FlattenPresetShelfIndexes(shelves) == std::vector<size_t>{2, 4, 1, 5, 0, 6, 3}));
}

}  // namespace


namespace
{

void TestCategoryGroupedShelves()
{
    using namespace RoonVis;
    std::vector<PresetShelfInput> inputs;
    auto add = [&inputs](size_t index, const char *file, const char *cat, const char *sub, bool fav = false) {
        PresetShelfInput input;
        input.index = index;
        input.filename = file;
        input.title = file;
        input.favorite = fav;
        input.category = cat;
        input.subcategory = sub;
        inputs.push_back(input);
    };
    add(0, "a.milk", "Fractal", "Lattice");
    add(1, "b.milk", "Fractal", "Lattice");
    add(2, "c.milk", "Dancer", "Glowsticks");
    add(3, "d.milk", "Fractal", "Organic");

    auto shelves = BuildPresetShelves(inputs, false);
    // One shelf per (category, subcategory), ordered by category then sub -
    // no runtime tiny-sub merge (pack time owns <Top>/Other).
    REQUIRE(shelves.size() == 3);
    CHECK(shelves[0].category == "Dancer");
    CHECK(shelves[0].title == "Glowsticks");
    CHECK(shelves[0].indexes.size() == 1);
    CHECK(shelves[1].category == "Fractal");
    CHECK(shelves[1].title == "Lattice");
    CHECK(shelves[1].indexes.size() == 2);
    CHECK(shelves[2].title == "Organic");

    // Favourites tab unchanged: single flat shelf regardless of categories.
    inputs[2].favorite = true;
    auto favShelves = BuildPresetShelves(inputs, true);
    REQUIRE(favShelves.size() == 1);
    CHECK(favShelves[0].title == "Favorites");

    // No category metadata -> author clustering fallback still works.
    std::vector<PresetShelfInput> plain;
    for (size_t i = 0; i < 4; i++)
    {
        PresetShelfInput input;
        input.index = i;
        input.filename = "flexi_-_test_" + std::to_string(i) + ".milk";
        input.title = input.filename;
        plain.push_back(input);
    }
    auto authorShelves = BuildPresetShelves(plain, false);
    REQUIRE(!authorShelves.empty());
    CHECK(authorShelves[0].category.empty());
}

} // namespace

void RunPresetShelfModelTests()
{
    TestCategoryGroupedShelves();
    TestAuthorClusterExtraction();
    TestShelvesFoldSmallClustersIntoOther();
    TestFavoritesNotDuplicatedAcrossShelves();
    TestFavoritesOnlyKeepsSegmentBehavior();
    TestFlattenPresetShelfIndexesFollowsBrowseOrderWithoutDuplicates();
}
