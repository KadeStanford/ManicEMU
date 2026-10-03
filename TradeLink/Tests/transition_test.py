"""Synthetic register/command trace of FireRed's cable-club -> party-list path.

Derived from pret/pokefirered's Task_StartWiredTrade, CB2_CreateTradeMenu,
OpenLink, ResetSerial and EnableSerial/DisableSerial. No ROM or game assets.
This exercises the real gpSP core, rather than executing FireRed game logic.
"""
from network_test import Peer, handshake, exchange, settle, close


def command_pair(master, slave, cmd, arg=0):
    exchange(master, slave, [cmd, arg] + [0]*6, [cmd, arg] + [0]*6)


def reopen(master, slave, delay=5, first_slave=False):
    # Real EnableSerial also writes RCNT=0. The repeated IRQ toggles must not
    # create a new pairing/checkpoint, flush SRAM, or consume serial while off.
    first, second = (slave, master) if first_slave else (master, slave)
    for peer in (first, second):
        epoch, flushes = peer.epoch, peer.flushes
        for value in (0x2000, 0x6003, 0x2000, 0x2000, 0x6003, 0x2000):
            peer.command(f'sio {value:x}')
        peer.command('idle 300000')
        peer.command(f'frames {delay}')
        peer.command('rcnt 0')
        peer.command('sio 6003')
        assert peer.phase == 3 and peer.flushes == flushes and peer.epoch == epoch
    settle(master, slave)
    handshake(master, slave)


def internal_close(master, slave, reason=0, delay=5, first_slave=False):
    flushes = {peer:peer.flushes for peer in (master, slave)}
    command_pair(master, slave, 0x5fff, reason)
    for peer in (master, slave):
        peer.command('sio 2000')
        peer.command('frame')
        assert peer.phase == 3 and peer.flushes == flushes[peer], (
            'FireRed party-list transition incorrectly ended the network '
            'session or flushed the save', peer.phase, peer.flushes)
    settle(master, slave)
    for peer in (master, slave):peer.command(f'frames {delay}')
    reopen(master, slave, first_slave=first_slave)


def block(master, slave, size, seed):
    # INIT_BLOCK advertises a byte count, CONT_BLOCK carries 7 little-endian
    # halfwords. Synthetic party/mail/turn buffers have no Pokemon data.
    command_pair(master, slave, 0xbbbb, size)
    source = bytes((i*13 + seed) & 255 for i in range(size))
    remote = bytes((i*29 + seed + 1) & 255 for i in range(size))
    for offset in range(0, size, 14):
        a = source[offset:offset+14].ljust(14, b'\0')
        b = remote[offset:offset+14].ljust(14, b'\0')
        exchange(master, slave, [0x8888] + [int.from_bytes(a[i:i+2], 'little') for i in range(0,14,2)],
                 [0x8888] + [int.from_bytes(b[i:i+2], 'little') for i in range(0,14,2)])
    assert master.phase == slave.phase == 3


def finish(master, slave):
    command_pair(master, slave, 0x5fff)
    for peer in (master, slave):peer.command('mutate');peer.command('sio 2000')
    settle(master, slave)
    # 179 frames is explicitly insufficient. Both games still use the same
    # session until the quiet deadline, after all state/DATA ACKs.
    for peer in (master, slave):
        peer.command('frames 179')
        assert peer.phase == 3 and peer.flushes == 0
        peer.command('frame')
    for _ in range(3):
        settle(master, slave)
        for peer in (master, slave):peer.command('frame')
    for peer in (master, slave):
        peer.command('frame')
        assert peer.phase == 1 and peer.flushes == 1 and peer.sram == 0x99
        peer.command('stopped')


def party_entry(ending=finish):
    master, slave = Peer(0), Peer(1)
    try:
        handshake(master, slave)
        exchange(master, slave, [0x2222, 0x1111] + [0]*6, [0x2222, 0x1111] + [0]*6)
        # Task_StartWiredTrade -> CB2_CreateTradeMenu. Include a delayed peer;
        # it still must fit within the explicitly bounded idle grace window.
        internal_close(master, slave, delay=90, first_slave=True)
        command_pair(master, slave, 0x2222, 0x1122)
        # BufferTradeParties: three 200-byte transfers (two mons per block).
        for request in range(3):
            command_pair(master, slave, 0xcccc, 1)
            block(master, slave, 200, 17+request)
        block(master, slave, 220, 31) # Synthetic mail/ribbon-sized transfer.
        for cmd in (0xaabb,0xdddd,0xccdd):command_pair(master, slave, cmd)
        # Trade selection closes again with reason 32, then the animation opens
        # LINKTYPE_TRADE_DISCONNECTED. v0.3 broke this path too.
        internal_close(master, slave, reason=32)
        command_pair(master, slave, 0x2222, 0x1144)
        block(master, slave, 100, 47)
        for _ in range(4):command_pair(master, slave, 0x2ffe)
        # Save/animation ending returns to the menu with another logical link.
        internal_close(master, slave)
        command_pair(master, slave, 0x2222, 0x1122)
        # Cancel menu -> reestablish overworld, still paired to same friend.
        internal_close(master, slave, reason=12)
        command_pair(master, slave, 0x2222, 0x1111)
        assert master.phase == slave.phase == 3
        ending(master, slave)
        print('PASS: FireRed room -> party-list -> three 200-byte party blocks -> '
              'selection -> animation -> save standby -> menu -> room -> normal exit; '
              'synthetic trace, same paired session, no intermediate save flush')
    finally:
        close(master)
        close(slave)


def battle_transitions():
    for kind in (0x2233,0x2244):
        master, slave = Peer(0), Peer(1)
        try:
            handshake(master, slave)
            command_pair(master, slave, 0x2222, kind)
            internal_close(master, slave, delay=20)
            command_pair(master, slave, 0x2222, 0x2211)
            assert master.mode == slave.mode == (2 if kind == 0x2233 else 3)
            for turn in range(12):block(master, slave, 28, 61+turn)
            # Finish/forfeit return-to-room handoff must survive reestablishment.
            internal_close(master, slave, first_slave=True)
            command_pair(master, slave, 0x2222, kind)
            finish(master, slave)
        finally:
            close(master);close(slave)
    print('PASS: Single/Double room -> battle entry -> synthetic turns -> '
          'finish/forfeit handoff -> room -> quiet normal exit')


def reset_without_close():
    master, slave = Peer(0), Peer(1)
    try:
        handshake(master, slave)
        # A register/mode reset without bilateral 5FFF cannot claim success,
        # even after the grace window. Disconnect still offers explicit recovery.
        for peer in (master, slave):peer.command('rcnt 8000')
        settle(master, slave)
        for peer in (master, slave):
            peer.command('frames 200');assert peer.phase == 3 and peer.flushes == 0
            peer.command('disconnected');assert peer.expected == 0
        reopen(master, slave)
        command_pair(master, slave, 0x2222, 0x1133)
        internal_close(master, slave)
        command_pair(master, slave, 0x2222, 0x1111)
    finally:
        close(master);close(slave)
    print('PASS: mode resets without close intent never finalize or overwrite saves')


def asymmetric_idle():
    master, slave = Peer(0), Peer(1)
    try:
        handshake(master, slave)
        command_pair(master, slave, 0x5fff)
        for peer in (master, slave):peer.command('sio 2000')
        settle(master, slave)
        master.command('frames 200')
        slave.command('frames 60')
        settle(master, slave)
        master.command('frames 200')
        assert master.phase == slave.phase == 3 and master.flushes == slave.flushes == 0
        # Only one quiet-ready notification is present. The slower game reopens
        # before its deadline, cancelling the faster peer's finalization too.
        reopen(master, slave, first_slave=True)
        command_pair(master, slave, 0x2222, 0x1122)
        block(master, slave, 200, 89)
    finally:
        close(master);close(slave)
    print('PASS: unequal frame rates require both quiet-ready barriers; slower reopen cancels both exits')


if __name__ == '__main__':
    party_entry()
    battle_transitions()
    reset_without_close()
    asymmetric_idle()
