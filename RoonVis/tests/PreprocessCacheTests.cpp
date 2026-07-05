#include "PreprocessCache.h"
#include "TestHarness.h"

#include <string>

using RoonVis::PreprocessCache;

namespace
{

void TestMissThenPutThenHit()
{
    PreprocessCache cache(8);
    std::string out = "untouched";

    CHECK(!cache.Get("k1", out));
    CHECK(out == "untouched");  // miss leaves valueOut untouched
    CHECK(cache.Misses() == 1);
    CHECK(cache.Hits() == 0);

    cache.Put("k1", "v1");
    CHECK(cache.Size() == 1);

    CHECK(cache.Get("k1", out));
    CHECK(out == "v1");
    CHECK(cache.Hits() == 1);
    CHECK(cache.Misses() == 1);
}

void TestOverwriteViaPut()
{
    PreprocessCache cache(8);
    cache.Put("k", "a");
    cache.Put("k", "b");
    CHECK(cache.Size() == 1);
    std::string out;
    CHECK(cache.Get("k", out));
    CHECK(out == "b");
}

void TestLruEvictionAtCapacity()
{
    PreprocessCache cache(2);
    cache.Put("a", "1");
    cache.Put("b", "2");
    cache.Put("c", "3");  // evicts LRU ("a")
    CHECK(cache.Size() == 2);

    std::string out;
    CHECK(!cache.Get("a", out));  // evicted
    CHECK(cache.Get("b", out) && out == "2");
    CHECK(cache.Get("c", out) && out == "3");
}

void TestGetPromotesToMru()
{
    PreprocessCache cache(2);
    cache.Put("a", "1");
    cache.Put("b", "2");

    // Touch "a" so it becomes MRU; inserting "c" should then evict "b", not "a".
    std::string out;
    CHECK(cache.Get("a", out) && out == "1");
    cache.Put("c", "3");

    CHECK(cache.Get("a", out) && out == "1");   // survived
    CHECK(!cache.Get("b", out));                // evicted
    CHECK(cache.Get("c", out) && out == "3");
}

void TestSeedCounterAndRetrieval()
{
    PreprocessCache cache(8);
    cache.Seed("s1", "sv1");
    cache.Seed("s2", "sv2");
    CHECK(cache.Seeds() == 2);
    CHECK(cache.Hits() == 0);    // seeding is not a hit
    CHECK(cache.Misses() == 0);  // ...nor a miss

    std::string out;
    CHECK(cache.Get("s1", out) && out == "sv1");
    CHECK(cache.Hits() == 1);
    CHECK(cache.Seeds() == 2);   // unchanged by the Get
}

void TestDefaultCapacityAndClamp()
{
    PreprocessCache dflt;
    CHECK(dflt.Capacity() == RoonVis::kPreprocessCacheDefaultCapacity);

    PreprocessCache zero(0);
    CHECK(zero.Capacity() >= 1);  // clamped
    zero.Put("k", "v");
    std::string out;
    CHECK(zero.Get("k", out) && out == "v");
}

}  // namespace

void RunPreprocessCacheTests()
{
    TestMissThenPutThenHit();
    TestOverwriteViaPut();
    TestLruEvictionAtCapacity();
    TestGetPromotesToMru();
    TestSeedCounterAndRetrieval();
    TestDefaultCapacityAndClamp();
}
