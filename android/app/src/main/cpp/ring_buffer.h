#ifndef ORPHEUS_RING_BUFFER_H_
#define ORPHEUS_RING_BUFFER_H_

#include <atomic>
#include <cstddef>
#include <vector>

namespace orpheus {

/** Lock-free SPSC ring for float mono samples (producer: Oboe input callback). */
class RingBuffer {
public:
    void reset(size_t capacitySamples);

    /** Returns samples actually written (may be less if full). */
    size_t write(const float* data, size_t count);

    /** Consumer (worker thread) — returns samples read. */
    size_t read(float* dest, size_t maxCount);

    size_t available() const;

private:
    std::vector<float> buffer_;
    size_t capacity_{0};
    std::atomic<size_t> writePos_{0};
    std::atomic<size_t> readPos_{0};
};

}  // namespace orpheus

#endif  // ORPHEUS_RING_BUFFER_H_
