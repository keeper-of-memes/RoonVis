#include "PreprocessCache.h"

#include <algorithm>

namespace RoonVis
{

PreprocessCache::PreprocessCache(size_t capacity)
    : capacity_(std::max<size_t>(1, capacity))
{
}

bool PreprocessCache::Get(const std::string& key, std::string& valueOut)
{
    auto it = map_.find(key);
    if (it == map_.end())
    {
        ++misses_;
        return false;
    }

    // Promote to most-recently-used.
    entries_.splice(entries_.begin(), entries_, it->second);
    valueOut = it->second->second;
    ++hits_;
    return true;
}

void PreprocessCache::Put(const std::string& key, std::string value)
{
    Store(key, std::move(value));
}

void PreprocessCache::Seed(const std::string& key, std::string value)
{
    Store(key, std::move(value));
    ++seeds_;
}

void PreprocessCache::EnsureCapacity(size_t capacity)
{
    capacity_ = std::max(capacity_, capacity);
}

void PreprocessCache::Store(const std::string& key, std::string value)
{
    auto it = map_.find(key);
    if (it != map_.end())
    {
        it->second->second = std::move(value);
        entries_.splice(entries_.begin(), entries_, it->second);
        return;
    }

    entries_.emplace_front(key, std::move(value));
    map_[key] = entries_.begin();

    while (map_.size() > capacity_)
    {
        const Entry& lru = entries_.back();
        map_.erase(lru.first);
        entries_.pop_back();
    }
}

}  // namespace RoonVis
