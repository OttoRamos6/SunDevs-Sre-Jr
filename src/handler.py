import base64
import hashlib
import json
import logging
import os
import socket
import ssl
import uuid
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

S3_BUCKET = os.environ["S3_BUCKET"]
REDIS_HOST = os.environ["REDIS_HOST"]
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))
REDIS_SECRET_ARN = os.environ["REDIS_SECRET_ARN"]
REDIS_TTL = int(os.environ.get("REDIS_TTL_SECONDS", "60"))

s3 = boto3.client("s3")
secretsmanager = boto3.client("secretsmanager")
redis_client = None


class RedisRESPClient:
    """Minimal RESP client using TLS and ElastiCache AUTH token."""

    def __init__(self, host, port, auth_token):
        self.host = host
        self.port = port
        self.auth_token = auth_token
        self.connection = None

    def _encode(self, parts):
        chunks = [f"*{len(parts)}\r\n".encode()]
        for part in parts:
            value = str(part).encode("utf-8")
            chunks.extend([f"${len(value)}\r\n".encode(), value, b"\r\n"])
        return b"".join(chunks)

    def _read_line(self):
        data = bytearray()
        while not data.endswith(b"\r\n"):
            chunk = self.connection.recv(1)
            if not chunk:
                raise ConnectionError("Redis closed the connection.")
            data.extend(chunk)
        return bytes(data[:-2])

    def _read_response(self):
        prefix = self.connection.recv(1)
        if not prefix:
            raise ConnectionError("Redis returned an empty response.")
        line = self._read_line()
        if prefix == b"+":
            return line.decode("utf-8")
        if prefix == b"-":
            raise RuntimeError(f"Redis error: {line.decode(errors='replace')}")
        if prefix == b":":
            return int(line)
        if prefix == b"$":
            length = int(line)
            if length == -1:
                return None
            data = bytearray()
            while len(data) < length + 2:
                chunk = self.connection.recv(length + 2 - len(data))
                if not chunk:
                    raise ConnectionError("Incomplete Redis response.")
                data.extend(chunk)
            if not data.endswith(b"\r\n"):
                raise ConnectionError("Invalid RESP terminator.")
            return bytes(data[:-2]).decode("utf-8")
        raise RuntimeError(f"Unsupported RESP response type: {prefix!r}")

    def _connect(self):
        context = ssl.create_default_context()
        raw_socket = socket.create_connection((self.host, self.port), timeout=3)
        self.connection = context.wrap_socket(raw_socket, server_hostname=self.host)
        self.connection.settimeout(3)
        self.connection.sendall(self._encode(("AUTH", self.auth_token)))
        self._read_response()

    def execute(self, *args):
        for attempt in range(2):
            try:
                if self.connection is None:
                    self._connect()
                self.connection.sendall(self._encode(args))
                return self._read_response()
            except (OSError, ssl.SSLError, ConnectionError):
                self.close()
                if attempt == 1:
                    raise

    def close(self):
        if self.connection is not None:
            try:
                self.connection.close()
            except OSError:
                pass
            finally:
                self.connection = None


def get_redis_client():
    """Fetch token from Secrets Manager once per warm Lambda environment."""
    global redis_client
    if redis_client is None:
        response = secretsmanager.get_secret_value(SecretId=REDIS_SECRET_ARN)
        token = response.get("SecretString")
        if not token:
            raise RuntimeError("Redis secret does not contain a SecretString token.")
        redis_client = RedisRESPClient(REDIS_HOST, REDIS_PORT, token)
    return redis_client


def build_response(status, body, cache_status=None):
    headers = {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Content-Type,Authorization,X-Amz-Date,X-Api-Key,X-Amz-Security-Token",
        "Access-Control-Allow-Methods": "OPTIONS,POST",
    }
    if cache_status:
        headers["X-Cache"] = cache_status
    return {"statusCode": status, "headers": headers, "body": json.dumps(body, ensure_ascii=False)}


def lambda_handler(event, context):
    try:
        raw_body = event.get("body") or "{}"
        if event.get("isBase64Encoded"):
            raw_body = base64.b64decode(raw_body).decode("utf-8")
        body = json.loads(raw_body) if isinstance(raw_body, str) else raw_body
        if not isinstance(body, dict):
            return build_response(400, {"error": "The request body must be a JSON object."})
        text = body.get("text")
        if not isinstance(text, str) or not text.strip():
            return build_response(400, {"error": "A non-empty string field named 'text' is required."})

        cache_key = "process:" + hashlib.sha256(text.encode("utf-8")).hexdigest()
        redis = get_redis_client()
        cached = redis.execute("GET", cache_key)
        if cached is not None:
            logger.info("Cache HIT key=%s", cache_key)
            return build_response(200, json.loads(cached), "HIT")

        now = datetime.now(timezone.utc)
        result = {
            "input": text,
            "output": text[::-1],
            "processed_at": now.isoformat(),
        }
        date_prefix = now.strftime("%Y-%m-%d")
        object_key = f"results/{date_prefix}/{uuid.uuid4()}.json"
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=object_key,
            Body=json.dumps(result, ensure_ascii=False).encode("utf-8"),
            ContentType="application/json",
        )
        result["s3_key"] = object_key
        redis.execute("SET", cache_key, json.dumps(result, ensure_ascii=False), "EX", REDIS_TTL)
        logger.info("Cache MISS key=%s s3_key=%s ttl=%s", cache_key, object_key, REDIS_TTL)
        return build_response(200, result, "MISS")
    except Exception:
        logger.exception("Request processing failed. request_id=%s", getattr(context, "aws_request_id", "unknown"))
        return build_response(500, {
            "error": "Unable to process request. Check CloudWatch logs for details.",
            "request_id": getattr(context, "aws_request_id", "unknown"),
        })
