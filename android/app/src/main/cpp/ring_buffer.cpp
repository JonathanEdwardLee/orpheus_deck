#include "ring_buffer.h"

namespace orpheus {

void RingBuffer::reset(size_t capacitySamples) {
    capacity_ = capacitySamples > 0 ? capacitySamples : 1;
    buffer_.assign(capacity_, 0.0f);
    writePos_.store(0, std::memory_order_relaxed);
    readPos_.store(0, std::memory_order_relaxed);
}

size_t RingBuffer::available() const {
    const size_t w = writePos_.load(std::memory_order_acquire);
    const size_t r = readPos_.load(std::memory_order_acquire);
    if (w >= r) {
        return w - r;
    }
    return capacity_ - (r - w);
}

size_t RingBuffer::write(const float* data, size_t count) {
    if (count == 0 || capacity_ == 0) {
        return 0;
    }
    size_t written = 0;
    while (written < count) {
        const size_t w = writePos_.load(std::memory_order_relaxed);
        const size_t r = readPos_.load(std::memory_order_acquire);
        size_t used = (w >= r) ? (w - r) : (capacity_ - (r - w));
        if (used >= capacity_) {
            break;
        }
        buffer_[w] = data[written++];
        writePos_.store((w + 1) % capacity_, std::memory_order_release);
    }
    return written;
}

size_t RingBuffer::read(float* dest, size_t maxCount) {
    size_t readTotal = 0;
    while (readTotal < maxCount) {
        const size_t r = readPos_.load(std::memory_order_relaxed);
        const size_t w = writePos_.load(std::memory_order_acquire);
        if (r == w) {
            break;
        }
        dest[readTotal++] = buffer_[r];
        readPos_.store((r + 1) % capacity_, std::memory_order_release);
    }
    return readTotal;
}

}  // namespace orpheus
