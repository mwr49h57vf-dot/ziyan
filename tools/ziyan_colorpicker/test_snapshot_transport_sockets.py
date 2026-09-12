"""Real socket timeout and recovery through the production C HTTP collector."""
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
from contextlib import contextmanager


@unittest.skipUnless(shutil.which("gcc"), "C compiler required")
class SocketContract(unittest.TestCase):
    @contextmanager
    def server(self, requests=2):
        framecap = Path(__file__).resolve().parents[1] / "ziyan_framecap"
        with tempfile.TemporaryDirectory(prefix="ziyan-http-contract-") as temp:
            executable = str(Path(temp) / "socket-fixture.exe")
            subprocess.run(["gcc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(framecap / "snapshot_socket_fixture.c"), "-lws2_32", "-o", executable], check=True, capture_output=True)
            server = subprocess.Popen([executable, str(requests)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                      creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            try:
                port = int(server.stdout.readline().strip())
                yield server, port
                output, error = server.communicate(timeout=3)
                self.assertEqual(server.returncode, 0, error)
                if output:
                    print(output.strip())
            finally:
                if server.poll() is None:
                    server.kill()
                    server.communicate()

    @staticmethod
    def response(client):
        result = b""
        while True:
            part = client.recv(65536)
            if not part:
                return result
            result += part

    def test_fragmented_and_complete_post_have_identical_body(self):
        body = b"main=0x123456&offs=" + b"a" * 5000
        header = b"POST /echo HTTP/1.1\r\nContent-Length: %d\r\n\r\n" % len(body)
        with self.server() as (_server, port):
            responses = []
            for pieces in ((header + body,), (header[:19], header[19:], body[:13], body[13:2100], body[2100:])):
                with socket.create_connection(("127.0.0.1", port), timeout=2) as client:
                    for piece in pieces:
                        client.sendall(piece)
                        time.sleep(.005)
                    responses.append(self.response(client))
            self.assertEqual(responses[0], responses[1])
            self.assertTrue(responses[0].endswith(body))

    def test_rejected_requests_do_not_reach_business_handler(self):
        cases = [
            (b"POST /echo HTTP/1.1\r\nContent-Length: 9\r\n\r\nx", True, b"400"),
            (b"POST /echo HTTP/1.1\r\n\r\n", False, b"411"),
            (b"POST /echo HTTP/1.1\r\nContent-Length: 65537\r\n\r\n", False, b"413"),
            (b"POST /echo HTTP/1.1\r\nContent-Length: x\r\n\r\n", False, b"400"),
            (b"POST /echo HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", False, b"501"),
            (b"POST /echo HTTP/1.1\r\nContent-Length: 9\r\n\r\nx", False, b"408"),
        ]
        with self.server(len(cases)) as (_server, port):
            for request, shutdown, status in cases:
                with self.subTest(status=status, shutdown=shutdown):
                    with socket.create_connection(("127.0.0.1", port), timeout=2) as client:
                        client.sendall(request)
                        if shutdown:
                            client.shutdown(socket.SHUT_WR)
                        response = self.response(client)
                        self.assertIn(b"HTTP/1.0 " + status, response)
                        self.assertTrue(response.endswith(b"Content-Length: 0\r\n\r\n"))

    def test_normal_large_response_arrives_complete(self):
        with self.server(1) as (_server, port):
            with socket.create_connection(("127.0.0.1", port), timeout=3) as client:
                client.sendall(b"GET /complete HTTP/1.1\r\n\r\n")
                response = self.response(client)
            header, body = response.split(b"\r\n\r\n", 1)
            self.assertIn(b"Content-Length: 2097152", header)
            self.assertEqual(body, b"x" * 2097152)

    def test_slow_receiver_releases_worker_for_health(self):
        with self.server() as (server, port):
                with socket.create_connection(("127.0.0.1", port), timeout=2) as slow:
                    slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                    slow.sendall(b"GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n")
                    started = time.monotonic()
                    with socket.create_connection(("127.0.0.1", port), timeout=2) as healthy:
                        for piece in (b"GET /hea", b"lth HTTP/1.1\r\n", b"Host: localhost\r\n", b"\r\n"):
                            healthy.sendall(piece)
                        data = b""
                        while True:
                            part = healthy.recv(1024)
                            if not part:
                                break
                            data += part
                    self.assertIn(b"200 Result", data)
                    self.assertTrue(data.endswith(b"ok\n"))
                    self.assertLess(time.monotonic()-started, 1.5)
                output, error = server.communicate(timeout=3)
                self.assertEqual(server.returncode, 0, error)
                self.assertIn("slow_complete=0", output)
                print(output.strip())


if __name__ == "__main__":
    unittest.main()
