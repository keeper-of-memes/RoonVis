#pragma once

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <list>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

struct sqlite3;

namespace RoonVis
{

// Tier-2 persistent EGL_ANDROID_blob_cache backing store: SQLite on disk, fronted by an
// in-memory LRU (registering app blob funcs makes ANGLE bypass its own caches entirely,
// so the memory tier lives here). Pure C++17, no Foundation/ObjC — host-testable.
//
// Threading model: every public method is thread-safe. ANGLE invokes the blob callbacks
// from worker threads AND the GL thread; gets may touch SQLite inline (reads), but puts
// only memcpy into a bounded queue — SQLite writes happen exclusively in DrainOnce(),
// intended to run on a single dedicated low-QoS writer thread (owned by the adapter).
// Lock order: `mutex_` (LRU/pins/queue/stats) and `dbMutex_` (SQLite handle) are never
// held simultaneously.
//
// Two-phase get contract (ANGLE probes size with value=nullptr, then fills): GetProbe
// PINS the hit value in an in-flight map so the bytes served to GetFill are exactly the
// probed bytes even if the row is evicted or replaced in between. A pin is cleared when
// consumed by GetFill, superseded by a newer probe for the same key, or rejected up
// front when the pinned-bytes cap would be exceeded (the probe then reports a miss).

struct ShaderBlobStoreOptions
{
    size_t dbCapBytes = 128u * 1024u * 1024u;    // on-disk LRU GC threshold
    size_t lruCapBytes = 32u * 1024u * 1024u;    // in-memory front cache
    size_t pinCapBytes = 32u * 1024u * 1024u;    // in-flight probe->fill pins
    size_t queueMaxEntries = 64;                 // pending-put queue bounds
    size_t queueMaxBytes = 32u * 1024u * 1024u;  // (drop-oldest on overflow)
};

struct ShaderBlobStoreStats
{
    uint64_t hits = 0;       // GetProbe found (memory or disk) and pinned
    uint64_t misses = 0;     // GetProbe found nothing (or pin cap rejected)
    uint64_t puts = 0;       // EnqueuePut accepted into the queue
    uint64_t evictions = 0;  // rows deleted by the on-disk LRU GC
    uint64_t dropped = 0;    // queued puts lost to overflow or a failed commit
};

class ShaderBlobStore
{
public:
    explicit ShaderBlobStore(ShaderBlobStoreOptions options = {});
    ~ShaderBlobStore();

    ShaderBlobStore(const ShaderBlobStore &) = delete;
    ShaderBlobStore &operator=(const ShaderBlobStore &) = delete;

    // Opens (or creates) the database at `path`. A corrupt or unopenable file is
    // deleted (with its -journal/-wal/-shm siblings) and recreated with a freshly
    // minted store generation. Returns false only if even the recreate fails.
    bool Open(const std::string &path);
    void Close();
    bool IsOpen() const;

    // UUID minted at CREATE and at every corruption-recreate; persisted in `metadata`.
    // Part II keys derived artifacts on this so a recreated store invalidates them.
    std::string Generation() const;

    // last_used clock, seconds resolution; injectable for deterministic tests.
    void SetClock(std::function<uint64_t()> clock);

    // Two-phase get. GetProbe returns the value size (0 = miss) and pins the value.
    // GetFill copies the pinned bytes into `out` (false if no pin or cap < size);
    // the pin is consumed either way. `filledSize` (optional) receives the number of
    // bytes copied on success — the EGL get callback must echo the probed size back.
    size_t GetProbe(const void *key, size_t keySize);
    bool GetFill(const void *key, size_t keySize, void *out, size_t cap,
                 size_t *filledSize = nullptr);

    // Copies key+value into the bounded pending queue (never touches SQLite inline).
    // On overflow the OLDEST queued put is dropped and `dropped` incremented.
    void EnqueuePut(const void *key, size_t keySize, const void *value, size_t valueSize);

    // Writer-thread body: commits all queued puts in one transaction, then runs the
    // on-disk LRU GC (delete oldest-last_used rows while total size > dbCapBytes).
    // Returns the number of puts committed (0 on empty queue or failed commit).
    size_t DrainOnce();

    // Blocks up to timeoutMs for pending puts (or shutdown). Returns true if the
    // queue is non-empty. NotifyShutdown wakes all waiters and makes further waits
    // return immediately so the owning thread can exit promptly.
    bool WaitForWork(int timeoutMs);
    void NotifyShutdown();

    // Durability watermark (Part II barrier hook). Every EnqueuePut gets a monotonic
    // sequence; CommittedSequence advances to the batch's max sequence only AFTER its
    // transaction commits. Overflow-dropped puts never commit themselves, but because
    // drops are oldest-first their sequences are covered when any later put commits;
    // at quiesce (final drain) CommittedSequence == LastEnqueuedSequence.
    uint64_t LastEnqueuedSequence() const;
    uint64_t CommittedSequence() const;

    ShaderBlobStoreStats Stats() const;

private:
    using Blob = std::shared_ptr<const std::vector<uint8_t>>;

    struct PendingPut
    {
        std::string key;
        std::vector<uint8_t> value;
        uint64_t sequence = 0;
    };

    struct LruEntry
    {
        std::string key;
        Blob value;
    };

    bool OpenLocked(const std::string &path);
    bool SetupSchemaLocked();
    void CloseLocked();
    static void DeleteDatabaseFiles(const std::string &path);
    static std::string MintGeneration();

    uint64_t Now() const;

    // In-memory LRU front (callers hold mutex_).
    void LruPut(const std::string &key, Blob value);
    Blob LruGet(const std::string &key);
    void LruErase(const std::string &key);

    // Pin map (callers hold mutex_). Installing may reject when over pinCapBytes.
    bool PinInstall(const std::string &key, const Blob &value);

    // SQLite helpers (callers hold dbMutex_).
    Blob DbLookup(const std::string &key, uint64_t now);
    size_t DbCollectGarbage(std::vector<std::string> *evictedKeys);

    ShaderBlobStoreOptions options_;

    mutable std::mutex mutex_;  // LRU + pins + queue + stats + watermarks
    std::condition_variable queueCondition_;
    std::deque<PendingPut> queue_;
    size_t queueBytes_ = 0;
    bool shutdown_ = false;

    std::list<LruEntry> lru_;  // front = most recent
    std::unordered_map<std::string, std::list<LruEntry>::iterator> lruIndex_;
    size_t lruBytes_ = 0;

    std::unordered_map<std::string, Blob> pins_;
    size_t pinnedBytes_ = 0;

    ShaderBlobStoreStats stats_;
    uint64_t lastEnqueuedSequence_ = 0;
    uint64_t committedSequence_ = 0;

    mutable std::mutex dbMutex_;  // SQLite handle + path + generation + clock
    sqlite3 *db_ = nullptr;
    std::string path_;
    std::string generation_;
    std::function<uint64_t()> clock_;
};

}  // namespace RoonVis
