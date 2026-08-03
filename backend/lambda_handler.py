"""
AWS Lambda entry point for the FastAPI "AI Digital Twin" application.
Wraps the FastAPI `app` (defined in `server.py`) with Mangum, an adapter
that translates AWS Lambda's event/context invocation format into ASGI
requests/responses that FastAPI understands, and vice versa for the
response. This allows the same FastAPI application to run unmodified as
a Lambda function (e.g. behind API Gateway or a Lambda Function URL)
instead of (or in addition to) running via Uvicorn as a standalone
server.
`handler` is the callable AWS Lambda invokes for each incoming request;
it must be referenced as the function's handler in the Lambda
configuration (e.g. `lambda_handler.handler`).
"""
from mangum import Mangum
from server import app

# Create the Lambda handler
handler = Mangum(app)