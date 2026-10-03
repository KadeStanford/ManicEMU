"""Exercise real Gen3 gpSP serial words across fragmented loopback TCP.

The legal fixture does not implement Pokemon game logic. This validates the
engine/transport boundary, not completion of an actual in-game trade.
"""
import socket
import subprocess
import sys
import time
import tempfile
from pathlib import Path


class Peer:
    def __init__(self, role, save=None):
        self.proc = subprocess.Popen([sys.argv[1], str(role)] + ([str(save)] if save else []), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True, bufsize=1)
        self.pending = []
        self.acks = []
        self.reg = []
        self.read()

    def read(self):
        while True:
            line = self.proc.stdout.readline().strip()
            if not line:
                assert self.proc.poll() is None, 'core process failed'
                continue
            if line == 'END':
                return
            if line.startswith('PACKET '):
                self.pending.append(bytes.fromhex(line[7:]))
            elif line.startswith('ACK '):
                self.acks.append(bytes.fromhex(line[4:]))
            elif line.startswith('REG '):
                words = line.split()
                self.reg = [int(v, 16) for v in words[1:5]]
                self.phase = int(words[6])
                self.rx = int(words[10])
                self.mode = int(words[12])
                self.sram = int(words[14])
                self.flushes = int(words[16])
                self.epoch = int(words[18])
                self.terminal = int(words[20])
            elif line.startswith('EXPECTED '):
                self.expected = int(line.split()[1])

    def command(self, text):
        self.proc.stdin.write(text + '\n')
        self.proc.stdin.flush()
        self.read()


def tcp_pair():
    server = socket.socket()
    server.bind(('127.0.0.1', 0))
    server.listen()
    a = socket.create_connection(server.getsockname(), timeout=5)
    b, _ = server.accept()
    b.settimeout(5)
    server.close()
    return a, b


def wire(message):
    # New transport after a drop; pending sequence and session remain in cores.
    a, b = tcp_pair()
    try:
        for offset in range(0, len(message), 7):
            a.sendall(message[offset:offset + 7])
            time.sleep(0.001)
        result = b''
        while len(result) < 56:
            part = b.recv(56 - len(result))
            assert part, 'truncated TCP packet'
            result += part
        return result
    finally:
        a.close()
        b.close()


def relay(source, dest, duplicate=False):
    packets, source.pending = source.pending, []
    for data in packets:
        dest.command('packet ' + wire(data).hex())
        before = dest.rx
        if duplicate:
            dest.command('packet ' + wire(data).hex())
            assert dest.rx == before, 'duplicate was executed again'
        acknowledgements, dest.acks = dest.acks, []
        for ack in acknowledgements:
            source.command('packet ' + wire(ack).hex())


def settle(master, slave):
    for _ in range(4):
        relay(master, slave, True)
        relay(slave, master, True)


def handshake(master, slave):
    master.command('master b9a0') # Also starts a fresh game-side subconnection.
    relay(master, slave, True)
    slave.command('slave b9a0 280065')
    relay(slave, master)
    master.command('master b9a0')
    relay(master, slave)
    master.command('master 8fff')
    relay(master, slave)
    slave.command('slave b9a0 280065')
    relay(slave, master)


def exchange(master, slave, a, b):
    master.command('master 0')
    for word in a: master.command(f'master {word:x}')
    relay(master, slave, True)
    slave.command('slave 0 28673')
    observed=[]
    for word in b:
        slave.command(f'slave {word:x} 28673')
        observed.append(slave.reg[0])
    assert observed == a, (observed, a)
    relay(slave, master, True)
    master.command('master 0')
    observed=[]
    for _ in range(8):
        master.command('master 0')
        observed.append(master.reg[1])
    assert observed == b, (observed, b)
    relay(master, slave)


def close(peer):
    peer.proc.stdin.write('quit\n')
    peer.proc.stdin.flush()
    assert peer.proc.wait(timeout=10)==0


def lifecycle():
    # Protocol fixtures use real IO/engine packets. They do not contain Pokemon
    # characters, parties, battle AI, save-sector checksums or game assets.
    for mode, order in [(0x1111,'master'),(0x2233,'slave'),(0x2244,'both')]:
        with tempfile.TemporaryDirectory() as directory:
            paths=[Path(directory)/f'{i}.sav' for i in range(2)]
            m,s=Peer(0,paths[0]),Peer(1,paths[1])
            try:
                handshake(m,s)
                # Identify Trade/Single/Double through actual LINKCMD, then
                # forward many block/turn packets, finish/forfeit close unchanged.
                exchange(m,s,[0x2222,mode,0,0,0,0,0,0],[0x2222,mode,0,0,0,0,0,0])
                assert m.mode==s.mode=={0x1111:1,0x2233:2,0x2244:3}[mode]
                if mode==0x2233:
                    # A reconnect burst exceeds gpSP's 128-frame engine queue.
                    # Transport keeps the tail until hardware consumes space.
                    burst=[[0x8888,turn]+[0x7100+i for i in range(6)] for turn in range(140)]
                    for frame in burst:
                        m.command('master 0')
                        for word in frame:m.command(f'master {word:x}')
                    relay(m,s,True);assert s.phase==3
                    for frame in burst:
                        s.command('slave 0 28673');observed=[]
                        for _ in range(8):s.command('slave 0 28673');observed.append(s.reg[0])
                        assert observed==frame, (observed,frame)
                    relay(s,m,True);assert m.phase==s.phase==3
                for turn in range(24):
                    exchange(m,s,[0x8888]+[(turn*8+i)&0xffff for i in range(7)],
                             [0x8888]+[(0x8000+turn*8+i)&0xffff for i in range(7)])
                for _ in range(3):
                    m.command('pause');settle(m,s)
                    assert m.phase==s.phase==4
                    m.command('resume');settle(m,s)
                    assert m.phase==s.phase==4, 'one-sided reconnect ran game'
                    s.command('resume');settle(m,s)
                    assert m.phase==s.phase==3
                exchange(m,s,[0x5fff,0,0,0,0,0,0,0],[0x5fff,0,0,0,0,0,0,0])
                for peer in (m,s):peer.command('mutate')
                first,second=(s,m) if order=='slave' else (m,s)
                first.command('leave')
                if order!='both':
                    settle(m,s)
                    assert first.phase==second.phase==3
                    first.command('frames 200');assert first.flushes==0, 'one-sided idle finalized'
                second.command('leave');settle(m,s)
                for peer in (m,s):peer.command('frames 180')
                for _ in range(3):
                    settle(m,s)
                    for peer in (m,s):peer.command('frame')
                for peer in (m,s):
                    peer.command('frame');assert peer.phase==1 and peer.flushes==1
                    peer.command('stopped')
                    peer.command('disconnected');assert peer.expected==1
                    peer.command('resume');peer.command('checksave');assert peer.phase==1
                for path in paths:assert len(path.read_bytes())==131072 and path.read_bytes()[0]==0x99
            finally:
                close(m);close(s)
            # New processes/restarted cores import the persisted changed battery.
            for role,path in enumerate(paths):
                peer=Peer(role,path)
                try:assert peer.sram==0x99
                finally:close(peer)
    # A disconnect during battle is not a CLOSE or a successful completion.
    m,s=Peer(0),Peer(1)
    try:
        handshake(m,s);exchange(m,s,[0x2222,0x2233,0,0,0,0,0,0],[0x2222,0x2233,0,0,0,0,0,0])
        for peer in (m,s):
            peer.command('mutate');peer.command('disconnected');assert peer.expected==0
            peer.command('pause');assert peer.phase==4 and peer.flushes==0
        settle(m,s)
        for peer in (m,s):
            peer.command('restore');assert peer.sram==0x45 and peer.phase==6
            peer.command('sio 2000');assert peer.phase==1, 'backing out after explicit recovery did not clear cancelled session'
    finally:close(m);close(s)
    print('PASS: real-core trade/single/double command + 24 block/turn frames, '
          '140-frame reconnect burst with engine backpressure, three bilateral reconnect rounds, bilateral quiet parent/child/simultaneous exits, '
          'no rollback/rejoin after ending, persisted SRAM in new processes, '
          'battle disconnect retains explicit checkpoint recovery')


def basic_network():
    peers = []
    try:
        master, slave = Peer(0), Peer(1)
        peers = [master, slave]
        relay(master, slave, True)
        slave.command('slave b9a0 280065')
        relay(slave, master)
        master.command('master b9a0')
        assert master.reg[1] == 0xb9a0, 'master did not discover slave'
        relay(master, slave)
        master.command('master 8fff')
        relay(master, slave)
        slave.command('slave b9a0 280065')
        assert slave.reg[0] == 0x8fff, 'slave did not receive master handshake'
        relay(slave, master)

        # Full 1+8 halfword frames. Sender game IO -> real serial protocol -> TCP ->
        # other core -> receiver game IO. No fabricated remote register values.
        outgoing = [0x1200 + i for i in range(8)]
        returning = [0x3400 + i for i in range(8)]
        master.command('master 0')
        for word in outgoing:
            master.command(f'master {word:x}')
        assert any(p[36] & 0x80 for p in master.pending), 'no data frame produced'

        # Disconnect halfway through a wire frame. No partial frame reaches a core.
        dropped = master.pending[0]
        a, b = tcp_pair()
        a.sendall(dropped[:19])
        a.close()
        partial = b.recv(56)
        b.close()
        assert len(partial) < 56
        master.command('pause')
        slave.command('pause')
        assert master.phase == slave.phase == 4
        time.sleep(0.08)
        master.command('resume')
        slave.command('resume')
        # PAUSE and both READY rounds travel in the same ordered stream as serial.
        for _ in range(4):
            relay(master, slave, True)
            relay(slave, master, True)
        assert master.phase == slave.phase == 3
        relay(master, slave, True)  # Retained, unacknowledged frames after reconnect.
        slave.command('slave 0 28673')
        observed = []
        for word in returning:
            slave.command(f'slave {word:x} 28673')
            observed.append(slave.reg[0])
        assert observed == outgoing, (observed, outgoing)
        relay(slave, master, True)
        master.command('master 0')
        observed = []
        for i in range(8):
            master.command('master 0')
            observed.append(master.reg[1])
        assert observed == returning, (observed, returning)
        relay(master, slave)
        for peer in peers:
            peer.command('restore')
            assert peer.phase == 6
        print('PASS: two real gpSP cores discover opposite link roles and exchange '
              '8-word Gen3 frames both ways over delayed/fragmented TCP; truncated '
              'connection, pause, retained retransmission, duplicate suppression, '
              'and independent battery/full-state recovery passed')
    finally:
        for peer in peers:
            if peer.proc.poll() is None:
                peer.proc.stdin.write('quit\n')
                peer.proc.stdin.flush()
            assert peer.proc.wait(timeout=10) == 0, 'core process failed on exit'


if __name__ == '__main__':
    basic_network()
    lifecycle()
