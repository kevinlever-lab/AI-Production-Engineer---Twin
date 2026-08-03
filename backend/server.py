"""
server.py — AI Digital Twin API
================================
FastAPI application providing a conversational AI endpoint powered by AWS Bedrock.
Supports persistent conversation memory via local file storage or AWS S3,
and is designed for deployment as an AWS Lambda function via Mangum or similar ASGI adapter.

Environment Variables:
    CORS_ORIGINS        Comma-separated list of allowed CORS origins (default: http://localhost:3000)
    DEFAULT_AWS_REGION  AWS region for Bedrock client (default: ap-southeast-2)
    BEDROCK_MODEL_ID    Bedrock model identifier (default: amazon.nova-lite-v1:0)
    USE_S3              Set to "true" to use S3 for conversation storage (default: false)
    S3_BUCKET           S3 bucket name for conversation storage (required if USE_S3 is true)
    MEMORY_DIR          Local directory for conversation storage (default: ../memory)

Endpoints:
    GET  /                          API info and configuration summary
    GET  /health                    Health check
    POST /chat                "      Send a message and receive an AI response
    GET  /conversation/{session_id} Retrieve conversation history for a session
"""
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import os
from dotenv import load_dotenv
from typing import Optional, List, Dict
import json
import uuid
from datetime import datetime
import boto3
from botocore.exceptions import ClientError
from context import prompt

# Load environment variables
load_dotenv()

app = FastAPI()

# Configure CORS
origins = os.getenv("CORS_ORIGINS", "http://localhost:3000").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

# Initialize Bedrock client - see Q42 on https://edwarddonner.com/faq if the Region gives you problems
bedrock_client = boto3.client(
    service_name="bedrock-runtime", 
    region_name=os.getenv("DEFAULT_AWS_REGION", "ap-southeast-2")
)

# Bedrock model selection - see Q42 on https://edwarddonner.com/faq for more
BEDROCK_MODEL_ID = os.getenv("BEDROCK_MODEL_ID", "amazon.nova-lite-v1:0")

# Memory storage configuration
USE_S3 = os.getenv("USE_S3", "false").lower() == "true"
S3_BUCKET = os.getenv("S3_BUCKET", "")
MEMORY_DIR = os.getenv("MEMORY_DIR", "../memory")

# Initialize S3 client if needed
if USE_S3:
    s3_client = boto3.client("s3")

# ─── Request / Response Models ────────────────────────────────────────────────

# Request/Response models
class ChatRequest(BaseModel):
    """
    Request body for the POST /chat endpoint.
    Attributes:
        message:    The user's message text to send to the AI.
        session_id: Optional session identifier for conversation continuity.
                    If omitted, a new UUID session is created automatically.
    """
    message: str
    session_id: Optional[str] = None


class ChatResponse(BaseModel):
    """
    Response body returned by the POST /chat endpoint.
    Attributes:
        response:   The AI assistant's reply text.
        session_id: The session identifier — either the one provided in the
                    request or a newly generated UUID. Use this in subsequent
                    requests to maintain conversation history.
    """
    response: str
    session_id: str


class Message(BaseModel):
    """
    Represents a single message in a conversation history record.
    Attributes:
        role:      The speaker — either "user" or "assistant".
        content:   The message text.
        timestamp: ISO 8601 timestamp of when the message was recorded.
    """
    role: str
    content: str
    timestamp: str

# ─── Memory Management ────────────────────────────────────────────────────────

# Memory management functions
def get_memory_path(session_id: str) -> str:
    """
    Return the storage key or filename for a session's conversation history.
    Used as the S3 object key when USE_S3 is true, or as the filename
    within MEMORY_DIR when using local file storage.
    Args:
        session_id: The unique session identifier.
    Returns:
        A string in the format "{session_id}.json".
    """
    return f"{session_id}.json"


def load_conversation(session_id: str) -> List[Dict]:
    """
    Load conversation history for a given session from storage.
    Reads from S3 if USE_S3 is true, otherwise reads from the local
    MEMORY_DIR directory. Returns an empty list if no history exists yet.
    Args:
        session_id: The unique session identifier.
    Returns:
        A list of message dictionaries, each containing 'role', 'content',
        and 'timestamp' keys. Returns an empty list for new sessions.
    Raises:
        ClientError: If an unexpected S3 error occurs (not including
                     NoSuchKey, which is handled as an empty history).
    """
    if USE_S3:
        try:
            response = s3_client.get_object(Bucket=S3_BUCKET, Key=get_memory_path(session_id))
            return json.loads(response["Body"].read().decode("utf-8"))
        except ClientError as e:
            if e.response["Error"]["Code"] == "NoSuchKey":
                return []
            raise
    else:
        # Local file storage
        file_path = os.path.join(MEMORY_DIR, get_memory_path(session_id))
        if os.path.exists(file_path):
            with open(file_path, "r") as f:
                return json.load(f)
        return []


def save_conversation(session_id: str, messages: List[Dict]):
    """
    Persist conversation history for a given session to storage.
    Writes to S3 if USE_S3 is true, otherwise writes to a JSON file
    in the local MEMORY_DIR directory (creating it if necessary).
    Args:
        session_id: The unique session identifier.
        messages:   The full list of message dictionaries to save,
                    each containing 'role', 'content', and 'timestamp'.
    """
    if USE_S3:
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=get_memory_path(session_id),
            Body=json.dumps(messages, indent=2),
            ContentType="application/json",
        )
    else:
        # Local file storage
        os.makedirs(MEMORY_DIR, exist_ok=True)
        file_path = os.path.join(MEMORY_DIR, get_memory_path(session_id))
        with open(file_path, "w") as f:
            json.dump(messages, f, indent=2)


def call_bedrock(conversation: List[Dict], user_message: str) -> str:
    """
    Send a conversation and a new user message to AWS Bedrock and return the AI response.
    Constructs the message list in Bedrock's converse API format, prepending
    the system prompt from context.prompt() as the first user message. Limits
    conversation history to the last 50 messages (25 exchanges) to stay within
    model context limits.
    Args:
        conversation:  The existing conversation history as a list of message
                       dictionaries with 'role' and 'content' keys.
        user_message:  The new user message text to send.
    Returns:
        The AI assistant's response text as a string.
    Raises:
        HTTPException 400: If Bedrock returns a ValidationException (malformed
                           message format).
        HTTPException 403: If Bedrock returns AccessDeniedException (model
                           access not enabled in the account/region).
        HTTPException 500: For all other Bedrock errors.
    """
    
    # Build messages in Bedrock format
    messages = []
    
    # Add system prompt as first user message
    # Or there's a better way to do this - pass in system=[{"text": prompt()}] to the converse call below
    messages.append({
        "role": "user", 
        "content": [{"text": f"System: {prompt()}"}]
    })
    
    # Add conversation history (limit to last 25 exchanges)
    for msg in conversation[-50:]:
        messages.append({
            "role": msg["role"],
            "content": [{"text": msg["content"]}]
        })
    
    # Add current user message
    messages.append({
        "role": "user",
        "content": [{"text": user_message}]
    })
    
    try:
        # Call Bedrock using the converse API
        response = bedrock_client.converse(
            modelId=BEDROCK_MODEL_ID,
            messages=messages,
            inferenceConfig={
                "maxTokens": 2000,
                "temperature": 0.7,
                "topP": 0.9
            }
        )
        
        # Extract the response text
        return response["output"]["message"]["content"][0]["text"]
        
    except ClientError as e:
        error_code = e.response['Error']['Code']
        if error_code == 'ValidationException':
            # Handle message format issues
            print(f"Bedrock validation error: {e}")
            raise HTTPException(status_code=400, detail="Invalid message format for Bedrock")
        elif error_code == 'AccessDeniedException':
            print(f"Bedrock access denied: {e}")
            raise HTTPException(status_code=403, detail="Access denied to Bedrock model")
        else:
            print(f"Bedrock error: {e}")
            raise HTTPException(status_code=500, detail=f"Bedrock error: {str(e)}")

# ─── Endpoints ────────────────────────────────────────────────────────────────

@app.get("/")
async def root():
    """
    Return a summary of the API configuration.
    Provides a human-readable overview of the current runtime configuration,
    including memory storage mode and the active Bedrock model. Useful for
    confirming correct deployment settings.
    Returns:
        dict: API description, memory status, storage backend, and model ID.
    """
    return {
        "message": "AI Digital Twin API (Powered by AWS Bedrock)",
        "memory_enabled": True,
        "storage": "S3" if USE_S3 else "local",
        "ai_model": BEDROCK_MODEL_ID
    }


@app.get("/health")
async def health_check():
    """
    Health check endpoint for load balancers and monitoring systems.
    Returns a lightweight response confirming the application is running,
    along with the current storage and model configuration. Called by
    API Gateway and AWS health checks to verify Lambda availability.
    Returns:
        dict: Status string, S3 storage flag, and active Bedrock model ID.
    """
    return {
        "status": "healthy", 
        "use_s3": USE_S3,
        "bedrock_model": BEDROCK_MODEL_ID
    }


@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    """
    Process a user message and return an AI response with conversation memory.
    Loads existing conversation history for the session, calls AWS Bedrock
    with the full conversation context, appends both the user message and
    AI response to the history, and persists the updated conversation.
    If no session_id is provided in the request, a new UUID is generated
    and returned in the response for use in subsequent requests.
    Args:
        request: ChatRequest containing the user's message and optional session_id.

    Returns:
        ChatResponse with the AI's reply and the session_id.

    Raises:
        HTTPException 400: If the message format is invalid for the Bedrock model.
        HTTPException 403: If access to the Bedrock model is denied.
        HTTPException 500: For storage errors or unexpected application errors.
    """
    try:
        # Generate session ID if not provided
        session_id = request.session_id or str(uuid.uuid4())

        # Load conversation history
        conversation = load_conversation(session_id)

        # Call Bedrock for response
        assistant_response = call_bedrock(conversation, request.message)

        # Update conversation history
        conversation.append(
            {"role": "user", "content": request.message, "timestamp": datetime.now().isoformat()}
        )
        conversation.append(
            {
                "role": "assistant",
                "content": assistant_response,
                "timestamp": datetime.now().isoformat(),
            }
        )

        # Save conversation
        save_conversation(session_id, conversation)

        return ChatResponse(response=assistant_response, session_id=session_id)

    except HTTPException:
        raise
    except Exception as e:
        print(f"Error in chat endpoint: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/conversation/{session_id}")
async def get_conversation(session_id: str):
    """
    Retrieve the full conversation history for a given session.
    Useful for debugging, auditing, or restoring conversation context
    in a client application. Returns all messages in chronological order.
    Args:
        session_id: The unique session identifier whose history to retrieve.
    Returns:
        dict: The session_id and a list of message dictionaries, each
              containing 'role', 'content', and 'timestamp'.
    Raises:
        HTTPException 500: If the conversation history cannot be loaded
                           from storage.
    """
    try:
        conversation = load_conversation(session_id)
        return {"session_id": session_id, "messages": conversation}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)