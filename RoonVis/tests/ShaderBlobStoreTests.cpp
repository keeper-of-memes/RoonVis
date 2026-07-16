#include "TestHarness.h"

#include "ShaderBlobStore.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

using namespace RoonVis;

namespace
{

// One temp dir per test run; each test uses its own database file inside it.
const std::string &TempDir()
{
    static const std::string dir = [] {
        const char *base = std::getenv("TMPDIR");
        std::string templatePath = base != nullptr ? base : "/tmp";
        if (!templatePath.empty() && templatePath.back() != '/')
        {
            templatePath += '/';
        }
        templatePath += "roonvis-blobstore-XXXXXX";
        std::vector<char> buffer(templatePath.begin(), templatePath.end());
        buffer.push_back('\0');
        const char *made = mkdtemp(buffer.data());
        return std::string(made != nullptr ? made : "/tmp");
    }();
    return dir;
}

std::string DbPath(const char *name)
{
    return TempDir() + "/" + name + ".sqlite";
}

std::vector<uint8_t> MakeValue(uint8_t seed, size_t size)
{
    std::vector<uint8_t> value(size);
    for (size_t i = 0; i < size; ++i)
    {
        value[i] = static_cast<uint8_t>(seed + i * 7);
    }
    return value;
}

bool ProbeAndFill(ShaderBlobStore &store, const std::string &key, std::vector<uint8_t> *out)
{
    const size_t size = store.GetProbe(key.data(), key.size());
    if (size == 0)
    {
        return false;
    }
    out->assign(size, 0);
    return store.GetFill(key.data(), key.size(), out->data(), out->size());
}

void TestOpenRoundtrip()
{
    ShaderBlobStore store;
    REQUIRE(store.Open(DbPath("roundtrip")));
    CHECK(store.IsOpen());
    CHECK(!store.Generation().empty());

    const std::string key = "key-roundtrip";
    const std::vector<uint8_t> value = MakeValue(3, 1000);
    store.EnqueuePut(key.data(), key.size(), value.data(), value.size());
    CHECK(store.DrainOnce() == 1);

    std::vector<uint8_t> fetched;
    CHECK(ProbeAndFill(store, key, &fetched));
    CHECK(fetched == value);

    const ShaderBlobStoreStats stats = store.Stats();
    CHECK(stats.puts == 1);
    CHECK(stats.hits == 1);
    CHECK(stats.dropped == 0);

    // Unknown key is a miss.
    const std::string missing = "no-such-key";
    CHECK(store.GetProbe(missing.data(), missing.size()) == 0);
    CHECK(store.Stats().misses == 1);
}

void TestGenerationPersistsAcrossReopen()
{
    const std::string path = DbPath("generation");
    std::string generation;
    {
        ShaderBlobStore store;
        REQUIRE(store.Open(path));
        generation = store.Generation();
        CHECK(!generation.empty());
    }
    ShaderBlobStore reopened;
    REQUIRE(reopened.Open(path));
    CHECK(reopened.Generation() == generation);
}

void TestProbeWithoutFillThenReprobe()
{
    ShaderBlobStore store;
    REQUIRE(store.Open(DbPath("reprobe")));

    const std::string key = "key-reprobe";
    const std::vector<uint8_t> value = MakeValue(9, 64);
    store.EnqueuePut(key.data(), key.size(), value.data(), value.size());
    store.DrainOnce();

    // Probe twice without filling: the second probe supersedes (replaces) the first
    // pin, so exactly one fill succeeds afterwards.
    CHECK(store.GetProbe(key.data(), key.size()) == value.size());
    CHECK(store.GetProbe(key.data(), key.size()) == value.size());
    std::vector<uint8_t> out(value.size());
    CHECK(store.GetFill(key.data(), key.size(), out.data(), out.size()));
    CHECK(out == value);
    CHECK(!store.GetFill(key.data(), key.size(), out.data(), out.size()));  // pin consumed

    // Fill with a too-small buffer fails AND consumes the pin.
    CHECK(store.GetProbe(key.data(), key.size()) == value.size());
    CHECK(!store.GetFill(key.data(), key.size(), out.data(), value.size() - 1));
    CHECK(!store.GetFill(key.data(), key.size(), out.data(), out.size()));
}

void TestFillWithoutProbeFails()
{
    ShaderBlobStore store;
    REQUIRE(store.Open(DbPath("nofill")));

    const std::string key = "key-nofill";
    const std::vector<uint8_t> value = MakeValue(1, 32);
    store.EnqueuePut(key.data(), key.size(), value.data(), value.size());
    store.DrainOnce();

    uint8_t out[32];
    CHECK(!store.GetFill(key.data(), key.size(), out, sizeof(out)));
}

void TestPinnedStabilityUnderEviction()
{
    // Disable the memory tier and use a tiny disk cap so the GC really evicts the
    // pinned row between the probe and the fill.
    ShaderBlobStoreOptions options;
    options.lruCapBytes = 0;
    options.dbCapBytes = 300;
    ShaderBlobStore store(options);
    REQUIRE(store.Open(DbPath("pin-evict")));

    const std::string key = "key-pinned";
    const std::vector<uint8_t> value = MakeValue(5, 100);
    store.EnqueuePut(key.data(), key.size(), value.data(), value.size());
    CHECK(store.DrainOnce() == 1);

    REQUIRE(store.GetProbe(key.data(), key.size()) == value.size());

    // Flood the store past the cap; the GC (oldest last_used first) evicts `key`.
    for (int i = 0; i < 4; ++i)
    {
        const std::string other = "filler-" + std::to_string(i);
        const std::vector<uint8_t> otherValue = MakeValue(static_cast<uint8_t>(i), 100);
        store.EnqueuePut(other.data(), other.size(), otherValue.data(), otherValue.size());
        store.DrainOnce();
    }
    CHECK(store.Stats().evictions > 0);

    // The pinned bytes must still fill, byte-identical to the probed value.
    std::vector<uint8_t> out(value.size());
    CHECK(store.GetFill(key.data(), key.size(), out.data(), out.size()));
    CHECK(out == value);

    // ...and the row really is gone from the store afterwards.
    CHECK(store.GetProbe(key.data(), key.size()) == 0);
}

void TestReplacementBetweenProbeAndFill()
{
    ShaderBlobStoreOptions options;
    options.lruCapBytes = 0;  // force the disk path so the replacement is observable
    ShaderBlobStore store(options);
    REQUIRE(store.Open(DbPath("pin-replace")));

    const std::string key = "key-replaced";
    const std::vector<uint8_t> v1 = MakeValue(11, 80);
    const std::vector<uint8_t> v2 = MakeValue(22, 200);
    store.EnqueuePut(key.data(), key.size(), v1.data(), v1.size());
    store.DrainOnce();

    REQUIRE(store.GetProbe(key.data(), key.size()) == v1.size());

    store.EnqueuePut(key.data(), key.size(), v2.data(), v2.size());
    store.DrainOnce();

    // The fill must serve the OLD pinned value, byte-stable with the probe.
    std::vector<uint8_t> out(v1.size());
    CHECK(store.GetFill(key.data(), key.size(), out.data(), out.size()));
    CHECK(out == v1);

    // A fresh probe then sees the replacement.
    CHECK(store.GetProbe(key.data(), key.size()) == v2.size());
    std::vector<uint8_t> out2(v2.size());
    CHECK(store.GetFill(key.data(), key.size(), out2.data(), out2.size()));
    CHECK(out2 == v2);
}

void TestConcurrentWriterChurnDuringGets()
{
    // Small fixed dataset (value derived from the key) so any successful fill can be
    // verified; disk path forced + tiny cap so GC/replacement churn under the reader.
    ShaderBlobStoreOptions options;
    options.lruCapBytes = 0;
    options.dbCapBytes = 4 * 100;  // ~4 of the 8 entries fit
    ShaderBlobStore store(options);
    REQUIRE(store.Open(DbPath("concurrent")));

    constexpr int kKeys = 8;
    constexpr int kWriterIterations = 400;
    auto keyName = [](int i) { return "churn-key-" + std::to_string(i); };
    auto keyValue = [](int i) { return MakeValue(static_cast<uint8_t>(i * 13 + 1), 100); };

    std::thread writer([&] {
        for (int i = 0; i < kWriterIterations; ++i)
        {
            const std::string key = keyName(i % kKeys);
            const std::vector<uint8_t> value = keyValue(i % kKeys);
            store.EnqueuePut(key.data(), key.size(), value.data(), value.size());
            store.DrainOnce();
        }
    });

    int verifiedFills = 0;
    int corruptFills = 0;
    for (int i = 0; i < kWriterIterations; ++i)
    {
        const int k = i % kKeys;
        const std::string key = keyName(k);
        const std::vector<uint8_t> expected = keyValue(k);
        const size_t size = store.GetProbe(key.data(), key.size());
        if (size == 0)
        {
            continue;  // legitimately evicted right now
        }
        std::vector<uint8_t> out(size, 0);
        if (!store.GetFill(key.data(), key.size(), out.data(), out.size()))
        {
            ++corruptFills;  // a pinned probe must always fill
            continue;
        }
        if (out == expected)
        {
            ++verifiedFills;
        }
        else
        {
            ++corruptFills;
        }
    }
    writer.join();

    CHECK(corruptFills == 0);
    CHECK(verifiedFills > 0);

    // Quiesced: every key still resident round-trips to its exact value.
    store.DrainOnce();
    for (int k = 0; k < kKeys; ++k)
    {
        const std::string key = keyName(k);
        std::vector<uint8_t> out;
        if (ProbeAndFill(store, key, &out))
        {
            CHECK(out == keyValue(k));
        }
    }
}

void TestCorruptionRecovery()
{
    const std::string path = DbPath("corrupt");
    const std::string key = "key-corrupt";
    std::string firstGeneration;
    {
        ShaderBlobStore store;
        REQUIRE(store.Open(path));
        firstGeneration = store.Generation();
        const std::vector<uint8_t> value = MakeValue(7, 128);
        store.EnqueuePut(key.data(), key.size(), value.data(), value.size());
        store.DrainOnce();
    }

    // Stomp the file with garbage.
    std::FILE *file = std::fopen(path.c_str(), "wb");
    REQUIRE(file != nullptr);
    for (int i = 0; i < 4096; ++i)
    {
        std::fputc(0xAB, file);
    }
    std::fclose(file);

    ShaderBlobStore recovered;
    REQUIRE(recovered.Open(path));  // deletes + recreates
    CHECK(!recovered.Generation().empty());
    CHECK(recovered.Generation() != firstGeneration);
    CHECK(recovered.GetProbe(key.data(), key.size()) == 0);  // old data gone

    // The recreated store is fully functional.
    const std::vector<uint8_t> value = MakeValue(8, 64);
    recovered.EnqueuePut(key.data(), key.size(), value.data(), value.size());
    CHECK(recovered.DrainOnce() == 1);
    std::vector<uint8_t> out;
    CHECK(ProbeAndFill(recovered, key, &out));
    CHECK(out == value);
}

void TestSequenceWatermark()
{
    ShaderBlobStore store;
    REQUIRE(store.Open(DbPath("watermark")));
    CHECK(store.LastEnqueuedSequence() == 0);
    CHECK(store.CommittedSequence() == 0);

    constexpr int kPuts = 5;
    for (int i = 0; i < kPuts; ++i)
    {
        const std::string key = "wm-key-" + std::to_string(i);
        const std::vector<uint8_t> value = MakeValue(static_cast<uint8_t>(i), 40);
        store.EnqueuePut(key.data(), key.size(), value.data(), value.size());
    }
    CHECK(store.LastEnqueuedSequence() == kPuts);
    CHECK(store.CommittedSequence() < kPuts);  // nothing durable until the drain

    CHECK(store.DrainOnce() == kPuts);
    CHECK(store.CommittedSequence() == kPuts);  // advances only after the commit
    CHECK(store.CommittedSequence() == store.LastEnqueuedSequence());
}

void TestLruEvictionOrderWithInjectedClock()
{
    ShaderBlobStoreOptions options;
    options.lruCapBytes = 0;
    options.dbCapBytes = 250;  // fits two 100-byte rows, not three
    ShaderBlobStore store(options);
    REQUIRE(store.Open(DbPath("lru-order")));

    uint64_t now = 1;
    store.SetClock([&now] { return now; });

    auto put = [&](const std::string &key) {
        const std::vector<uint8_t> value = MakeValue(static_cast<uint8_t>(key.back()), 100);
        store.EnqueuePut(key.data(), key.size(), value.data(), value.size());
        store.DrainOnce();
    };

    now = 1;
    put("lru-a");
    now = 2;
    put("lru-b");

    // Touch A at t=3 (probe+fill updates last_used), making B the oldest.
    now = 3;
    std::vector<uint8_t> out;
    CHECK(ProbeAndFill(store, "lru-a", &out));

    now = 4;
    put("lru-c");  // total 300 > 250: GC must evict exactly the oldest row = B

    CHECK(store.Stats().evictions == 1);
    const std::string keyA = "lru-a", keyB = "lru-b", keyC = "lru-c";
    CHECK(store.GetProbe(keyB.data(), keyB.size()) == 0);
    CHECK(store.GetProbe(keyA.data(), keyA.size()) == 100);
    CHECK(store.GetProbe(keyC.data(), keyC.size()) == 100);
}

void TestQueueOverflowDropsOldest()
{
    ShaderBlobStoreOptions options;
    options.lruCapBytes = 0;
    options.queueMaxEntries = 4;
    ShaderBlobStore store(options);
    REQUIRE(store.Open(DbPath("overflow")));

    for (int i = 0; i < 6; ++i)
    {
        const std::string key = "of-key-" + std::to_string(i);
        const std::vector<uint8_t> value = MakeValue(static_cast<uint8_t>(i), 50);
        store.EnqueuePut(key.data(), key.size(), value.data(), value.size());
    }
    CHECK(store.Stats().puts == 6);
    CHECK(store.Stats().dropped == 2);  // the two OLDEST puts fell off
    CHECK(store.DrainOnce() == 4);

    // Oldest two never reached the database; the newest four did.
    const std::string k0 = "of-key-0", k1 = "of-key-1";
    CHECK(store.GetProbe(k0.data(), k0.size()) == 0);
    CHECK(store.GetProbe(k1.data(), k1.size()) == 0);
    for (int i = 2; i < 6; ++i)
    {
        const std::string key = "of-key-" + std::to_string(i);
        std::vector<uint8_t> out;
        CHECK(ProbeAndFill(store, key, &out));
        CHECK(out == MakeValue(static_cast<uint8_t>(i), 50));
    }

    // Drop-oldest keeps the watermark honest: the committed batch's max sequence
    // covers the dropped (older) sequences.
    CHECK(store.CommittedSequence() == store.LastEnqueuedSequence());
}

void TestPinCapRejectsAsMiss()
{
    ShaderBlobStoreOptions options;
    options.pinCapBytes = 150;
    ShaderBlobStore store(options);
    REQUIRE(store.Open(DbPath("pin-cap")));

    const std::string keyA = "cap-a", keyB = "cap-b";
    const std::vector<uint8_t> value = MakeValue(1, 100);
    store.EnqueuePut(keyA.data(), keyA.size(), value.data(), value.size());
    store.EnqueuePut(keyB.data(), keyB.size(), value.data(), value.size());
    store.DrainOnce();

    // First pin fits; a second concurrent pin would exceed the cap and is rejected
    // (reported as a miss) instead of growing without bound.
    CHECK(store.GetProbe(keyA.data(), keyA.size()) == value.size());
    CHECK(store.GetProbe(keyB.data(), keyB.size()) == 0);

    // Consuming the first pin frees the budget.
    std::vector<uint8_t> out(value.size());
    CHECK(store.GetFill(keyA.data(), keyA.size(), out.data(), out.size()));
    CHECK(store.GetProbe(keyB.data(), keyB.size()) == value.size());
    CHECK(store.GetFill(keyB.data(), keyB.size(), out.data(), out.size()));
}

void TestWaitForWorkAndShutdown()
{
    ShaderBlobStore store;
    REQUIRE(store.Open(DbPath("wait")));

    CHECK(!store.WaitForWork(1));  // empty queue times out

    const std::string key = "wait-key";
    const std::vector<uint8_t> value = MakeValue(2, 16);
    store.EnqueuePut(key.data(), key.size(), value.data(), value.size());
    CHECK(store.WaitForWork(1));  // pending put reported immediately

    store.DrainOnce();
    store.NotifyShutdown();
    CHECK(!store.WaitForWork(60000));  // returns immediately post-shutdown, no work
}

}  // namespace

void RunShaderBlobStoreTests()
{
    TestOpenRoundtrip();
    TestGenerationPersistsAcrossReopen();
    TestProbeWithoutFillThenReprobe();
    TestFillWithoutProbeFails();
    TestPinnedStabilityUnderEviction();
    TestReplacementBetweenProbeAndFill();
    TestConcurrentWriterChurnDuringGets();
    TestCorruptionRecovery();
    TestSequenceWatermark();
    TestLruEvictionOrderWithInjectedClock();
    TestQueueOverflowDropsOldest();
    TestPinCapRejectsAsMiss();
    TestWaitForWorkAndShutdown();
}
