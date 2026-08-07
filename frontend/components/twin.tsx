'use client';

// Twin.tsx
// Chat interface component for the AI Digital Twin.
// Renders a full chat UI with message history, a typing indicator,
// an optional avatar image, and a text input. Communicates with the
// FastAPI backend via POST /chat, maintaining a session ID across
// messages so the backend can retrieve conversation context from S3.

import { useState, useRef, useEffect } from 'react';
import { Send, Bot, User } from 'lucide-react';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------
// Represents a single message in the conversation — either sent by the user
// or returned by the assistant. The id field is a timestamp string used as
// the React list key; timestamp is stored separately for display purposes.
interface Message {
    id: string;
    role: 'user' | 'assistant';
    content: string;
    timestamp: Date;
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------
export default function Twin() {
    // Full conversation history displayed in the chat window.
    const [messages, setMessages] = useState<Message[]>([]);
    // Current value of the text input field.
    const [input, setInput] = useState('');
    // True while waiting for the backend to respond — disables the input
    // and send button and shows the animated typing indicator.
    const [isLoading, setIsLoading] = useState(false);
    // Session ID returned by the backend on the first message and reused
    // for all subsequent messages so the backend can load conversation
    // history from S3 and maintain context across turns.
    const [sessionId, setSessionId] = useState<string>('');
    // Ref attached to an invisible div at the bottom of the message list —
    // scrolled into view after each new message to keep the latest message visible.
    const messagesEndRef = useRef<HTMLDivElement>(null);
    // Ref to the text input — used to refocus the input after a message is
    // sent so the user can type their next message without clicking.
    const inputRef = useRef<HTMLInputElement>(null);
    // Scroll the message list to the bottom whenever messages change.
    const scrollToBottom = () => {
        messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
    };

    useEffect(() => {
        scrollToBottom();
    }, [messages]);

    // -----------------------------------------------------------------------
    // Message sending
    // -----------------------------------------------------------------------
    const sendMessage = async () => {
        // Prevent sending empty messages or multiple concurrent requests.
        if (!input.trim() || isLoading) return;

        // Construct the user message and add it to the conversation immediately
        // so it appears in the UI before the API call completes (optimistic update).
        const userMessage: Message = {
            id: Date.now().toString(),
            role: 'user',
            content: input,
            timestamp: new Date(),
        };

        setMessages(prev => [...prev, userMessage]);
        setInput('');
        setIsLoading(true);

        try {
            // POST the message to the FastAPI backend.
            // NEXT_PUBLIC_API_URL is set at build time via environment variables;
            // falls back to localhost:8000 for local development.
            // session_id is omitted on the first message (undefined) so the backend
            // creates a new session; included on all subsequent messages so the
            // backend loads the existing conversation context.
            const response = await fetch(`${process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8000'}/chat`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    message: userMessage.content,
                    session_id: sessionId || undefined,
                }),
            });

            if (!response.ok) throw new Error('Failed to send message');

            const data = await response.json();

            // Store the session ID returned by the backend on the first message.
            // Once set, this persists for the lifetime of the component so all
            // subsequent messages are sent within the same session.
            if (!sessionId) {
                setSessionId(data.session_id);
            }

            // Add the assistant's response to the conversation.
            const assistantMessage: Message = {
                id: (Date.now() + 1).toString(),        // +1 avoids collision with the user message id generated above
                role: 'assistant',
                content: data.response,
                timestamp: new Date(),
            };

            setMessages(prev => [...prev, assistantMessage]);
        } catch (error) {
            console.error('Error:', error);
            // Show an inline error message in the chat rather than a modal/toast
            // so the user can see what happened in context and retry.
            const errorMessage: Message = {
                id: (Date.now() + 1).toString(),        
                role: 'assistant',
                content: 'Sorry, I encountered an error. Please try again.',
                timestamp: new Date(),
            };
            setMessages(prev => [...prev, errorMessage]);
        } finally {
            setIsLoading(false);
            // Refocus the input after the response arrives so the user can
            // type immediately. Wrapped in setTimeout to ensure the DOM has
            // updated and the input is re-enabled before focus is attempted.
            setTimeout(() => {
                inputRef.current?.focus();
            }, 100);
        }
    };

    // Send the message when Enter is pressed without Shift.
    // Shift+Enter is reserved for multi-line input (though the current
    // input is a single-line <input>, not a <textarea>).
    const handleKeyPress = (e: React.KeyboardEvent) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            sendMessage();
        }
    };

    // -----------------------------------------------------------------------
    // Avatar detection
    // -----------------------------------------------------------------------
    // Check whether a custom avatar image has been placed at /public/avatar.jpg.
    // If found, it replaces the default Bot icon in the header, empty state,
    // and beside each assistant message. Falls back to the Bot icon if missing.
    // The HEAD request avoids downloading the full image just to check existence.
    const [hasAvatar, setHasAvatar] = useState(false);
    useEffect(() => {
        // Check if avatar.jpg exists
        fetch('/avatar.jpg', { method: 'HEAD' })
            .then(res => setHasAvatar(res.ok))
            .catch(() => setHasAvatar(false));
    }, []);

    // -----------------------------------------------------------------------
    // Render
    // -----------------------------------------------------------------------
    return (
        <div className="flex flex-col h-full bg-gray-50 rounded-lg shadow-lg">
            {/* Header - gradient banner with the twin's name and tagline */}
            <div className="bg-gradient-to-r from-slate-700 to-slate-800 text-white p-4 rounded-t-lg">
                <h2 className="text-xl font-semibold flex items-center gap-2">
                    <Bot className="w-6 h-6" />
                    AI Digital Twin
                </h2>
                <p className="text-sm text-slate-300 mt-1">Your AI course companion</p>
            </div>

            {/* Message list — scrollable area that grows to fill available height */}
            <div className="flex-1 overflow-y-auto p-4 space-y-4">
                {/* Empty state — shown before the first message is sent */}
                {messages.length === 0 && (
                    <div className="text-center text-gray-500 mt-8">
                        {/* Show avatar image if available, otherwise fall back to Bot icon */}
                        {hasAvatar ? (
                            <img 
                                src="/avatar.jpg" 
                                alt="Digital Twin Avatar" 
                                className="w-20 h-20 rounded-full mx-auto mb-3 border-2 border-gray-300"
                            />
                        ) : (
                            <Bot className="w-12 h-12 mx-auto mb-3 text-gray-400" />
                        )}
                        <p>Hello! I'm Ed Donner's Digital Twin.</p>
                        <p className="text-sm mt-2">Ask me anything about AI deployment!</p>
                    </div>
                )}

                {/* Render each message in the conversation history */}
                {messages.map((message) => (
                    <div
                        key={message.id}
                        // User messages are right-aligned; assistant messages are left-aligned.
                        className={`flex gap-3 ${
                            message.role === 'user' ? 'justify-end' : 'justify-start'
                        }`}
                    >
                        {/* Assistant avatar — shown to the left of assistant messages only */}
                        {message.role === 'assistant' && (
                            <div className="flex-shrink-0">
                                {hasAvatar ? (
                                    <img 
                                        src="/avatar.jpg" 
                                        alt="Digital Twin Avatar" 
                                        className="w-8 h-8 rounded-full border border-slate-300"
                                    />
                                ) : (
                                    <div className="w-8 h-8 bg-slate-700 rounded-full flex items-center justify-center">
                                        <Bot className="w-5 h-5 text-white" />
                                    </div>
                                )}
                            </div>
                        )}

                        {/* Message bubble — dark for user, white for assistant */}
                        <div
                            className={`max-w-[70%] rounded-lg p-3 ${
                                message.role === 'user'
                                    ? 'bg-slate-700 text-white'
                                    : 'bg-white border border-gray-200 text-gray-800'
                            }`}
                        >
                            {/* whitespace-pre-wrap preserves newlines in multi-line responses */}
                            <p className="whitespace-pre-wrap">{message.content}</p>
                            {/* Timestamp shown in small text below the message content */}
                            <p
                                className={`text-xs mt-1 ${
                                    message.role === 'user' ? 'text-slate-300' : 'text-gray-500'
                                }`}
                            >
                                {message.timestamp.toLocaleTimeString()}
                            </p>
                        </div>

                        {/* User avatar — shown to the right of user messages only */}
                        {message.role === 'user' && (
                            <div className="flex-shrink-0">
                                <div className="w-8 h-8 bg-gray-600 rounded-full flex items-center justify-center">
                                    <User className="w-5 h-5 text-white" />
                                </div>
                            </div>
                        )}
                    </div>
                ))}

                {/* Typing indicator — three bouncing dots shown while waiting for a response */}
                {isLoading && (
                    <div className="flex gap-3 justify-start">
                        <div className="flex-shrink-0">
                            {hasAvatar ? (
                                <img 
                                    src="/avatar.jpg" 
                                    alt="Digital Twin Avatar" 
                                    className="w-8 h-8 rounded-full border border-slate-300"
                                />
                            ) : (
                                <div className="w-8 h-8 bg-slate-700 rounded-full flex items-center justify-center">
                                    <Bot className="w-5 h-5 text-white" />
                                </div>
                            )}
                        </div>
                        {/* Animated dots — each delayed slightly to create a wave effect */}
                        <div className="bg-white border border-gray-200 rounded-lg p-3">
                            <div className="flex space-x-2">
                                <div className="w-2 h-2 bg-gray-400 rounded-full animate-bounce" />
                                <div className="w-2 h-2 bg-gray-400 rounded-full animate-bounce delay-100" />
                                <div className="w-2 h-2 bg-gray-400 rounded-full animate-bounce delay-200" />
                            </div>
                        </div>
                    </div>
                )}

                {/* Invisible anchor div scrolled into view after each new message */}
                <div ref={messagesEndRef} />
            </div>

            {/* Input bar — fixed to the bottom of the chat window */}
            <div className="border-t border-gray-200 p-4 bg-white rounded-b-lg">
                <div className="flex gap-2">
                    <input
                        ref={inputRef}
                        type="text"
                        value={input}
                        onChange={(e) => setInput(e.target.value)}
                        onKeyDown={handleKeyPress}
                        placeholder="Type your message..."
                        className="flex-1 px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-slate-600 focus:border-transparent text-gray-800"
                        disabled={isLoading}
                        autoFocus
                    />
                    {/* Send button — disabled when input is empty or a request is in flight */}
                    <button
                        onClick={sendMessage}
                        disabled={!input.trim() || isLoading}
                        className="px-4 py-2 bg-slate-700 text-white rounded-lg hover:bg-slate-800 focus:outline-none focus:ring-2 focus:ring-slate-600 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
                    >
                        <Send className="w-5 h-5" />
                    </button>
                </div>
            </div>
        </div>
    );
}