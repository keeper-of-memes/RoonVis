#pragma once

#include <cstddef>
#include <list>
#include <string>
#include <unordered_map>
#include <utility>

namespace RoonVis
{

inline constexpr size_t kPreprocessCacheDefaultCapacity = 512;

// A plain key->value store for preprocessed-HLSL text keyed by an already-computed
// string. LRU eviction keeps the working set bounded (constructor capacity). Values are
// stored by move; Get copies the value out and ownership stays in the cache.
//
// NOT thread-safe. Single-threaded / caller-synchronized: all access must happen from a
// single thread (or under external synchronization). No internal locking.
class PreprocessCache
{
public:
    explicit PreprocessCache(size_t capacity = kPreprocessCacheDefaultCapacity);

    // Returns true and fills valueOut with a copy on a hit (bumps the hit counter, marks
    // the entry most-recently-used). On a miss returns false, leaves valueOut untouched,
    // and bumps the miss counter (misses == cold-preprocess count).
    bool Get(const std::string& key, std::string& valueOut);

    // Insert or update. Marks the entry most-recently-used and evicts the LRU entry while
    // over capacity. Does not touch the hit/miss/seed counters.
    void Put(const std::string& key, std::string value);

    // Like Put, but bumps the seed counter (build-time prepopulation). Not a hit/miss.
    void Seed(const std::string& key, std::string value);

    // Raise the capacity to at least `capacity` (never lowers it). Used before seeding the
    // build-time prepopulated entries so none of them can be evicted by later Puts.
    void EnsureCapacity(size_t capacity);

    size_t Seeds() const { return seeds_; }
    size_t Hits() const { return hits_; }
    size_t Misses() const { return misses_; }

    size_t Size() const { return map_.size(); }
    size_t Capacity() const { return capacity_; }

private:
    using Entry = std::pair<std::string, std::string>;
    using EntryList = std::list<Entry>;

    // Insert/update by move and promote to most-recently-used, then evict LRU over cap.
    void Store(const std::string& key, std::string value);

    size_t capacity_;
    EntryList entries_;  // front = most-recently-used, back = least-recently-used
    std::unordered_map<std::string, EntryList::iterator> map_;

    size_t seeds_ = 0;
    size_t hits_ = 0;
    size_t misses_ = 0;
};

}  // namespace RoonVis
