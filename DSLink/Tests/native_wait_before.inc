std::optional<Packet> MpState::NextPacket() noexcept {
    retro_assert(IsReady());
    if(receivedPackets.empty()) {
        _sendFn(RETRO_NETPACKET_FLUSH_HINT, NULL, 0, RETRO_NETPACKET_BROADCAST);
        _pollFn();
    }
    if(receivedPackets.empty()) {
        return std::nullopt;
    } else {
        _timeoutCount = 0;
        Packet p = receivedPackets.front();
        receivedPackets.pop();
        return p;
    }
}
std::optional<Packet> MpState::NextPacketBlock(uint32_t maximumWaitMicros) noexcept {
    retro_assert(IsReady());
    if (receivedPackets.empty()) {
        manicds::ReceiveDeadline deadline(std::chrono::microseconds(std::min(maximumWaitMicros,uint32_t(RECV_TIMEOUT_MS * 1000))));
        while(deadline.nextWaitMicros()) {
            _sendFn(RETRO_NETPACKET_FLUSH_HINT, NULL, 0, RETRO_NETPACKET_BROADCAST);
            _pollFn();
            if(!receivedPackets.empty()) {
                return NextPacket();
            }
            struct Wait { uint32_t microseconds; uint32_t reserved; } wait{deadline.nextWaitMicros(),0};
            if(wait.microseconds && !retro::environment(0x4d445302, &wait))
                std::this_thread::sleep_for(std::chrono::microseconds(wait.microseconds));
        }
    } else {
        return NextPacket();
    }
    struct Event { uint32_t event; uint32_t reserved; const void* packet; } event{4,0,nullptr};
    retro::environment(0x4d445301, &event);
    _timeoutCount++;
    if (_timeoutCount >= SUCCESSIVE_TIMEOUTS_WARNING && !_warnedHighLatency) {
        retro::set_warn_message("LAN Multiplayer will NOT work using VPNs or tunnels such as Hamachi!");
        _warnedHighLatency = true;
    }
    retro::debug("Timeout while waiting for packet");
    return std::nullopt;
}
