import React, { useState, useRef, useEffect } from 'react';
import authService from '../services/authService';
import bedrockService from '../services/bedrockService';
import MODELS from '../models';
import Header from './Header';

function Chat() {
  const [selectedModel, setSelectedModel] = useState(MODELS[0].id);
  const [messages, setMessages] = useState([]);
  const [input, setInput] = useState('');
  const [loading, setLoading] = useState(false);
  const messagesEndRef = useRef(null);

  const scrollToBottom = () => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  };

  useEffect(() => {
    scrollToBottom();
  }, [messages]);

  const handleSend = async () => {
    if (!input.trim() || loading) return;

    const userMessage = { role: 'user', content: [{ text: input }] };
    const conversationHistory = [...messages, userMessage];

    setMessages(prev => [...prev, userMessage]);
    setInput('');
    setLoading(true);

    // Add placeholder for assistant message
    const assistantIndex = messages.length + 1;
    setMessages(prev => [...prev, { role: 'assistant', content: [{ text: '' }], usage: null }]);

    try {
      let fullText = '';

      await bedrockService.sendMessageStream(
        selectedModel,
        conversationHistory,
        (chunk) => {
          fullText += chunk;
          setMessages(prev => {
            const updated = [...prev];
            updated[assistantIndex] = { role: 'assistant', content: [{ text: fullText }], usage: null };
            return updated;
          });
        }
      );
    } catch (error) {
      console.error('Error:', error);

      let errorText = 'Error: Failed to get response. Please try again.';
      if (error.message && error.message.startsWith('BUDGET_EXCEEDED:')) {
        const detail = error.message.replace('BUDGET_EXCEEDED: ', '');
        errorText = `⛔ ${detail} Please contact your administrator to increase your budget limit.`;
      } else if (error.message && error.message.includes('Rate limit')) {
        errorText = '⚠️ Rate limit exceeded. Please wait 30-60 seconds before trying again.';
      }

      setMessages(prev => {
        const updated = [...prev];
        updated[assistantIndex] = {
          role: 'assistant',
          content: [{ text: errorText }],
          usage: null,
          isError: true
        };
        return updated;
      });
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100vh', overflow: 'hidden' }}>
      <Header />
      <div style={{ display: 'flex', flex: 1, overflow: 'hidden' }}>
        {/* Sidebar */}
        <div style={{
          width: '280px',
          backgroundColor: '#f8f9fa',
          padding: '20px',
          flexShrink: 0,
          borderRight: '1px solid #dee2e6',
          display: 'flex',
          flexDirection: 'column'
        }}>
          <h4 style={{ color: '#ED1C24', marginBottom: '20px', fontWeight: 'bold' }}>AI Gateway</h4>

          <div style={{ marginBottom: '20px' }}>
            <label style={{ fontWeight: '600', marginBottom: '8px', display: 'block' }}>Select Model</label>
            <select
              className="form-select"
              value={selectedModel}
              onChange={(e) => setSelectedModel(e.target.value)}
              disabled={loading}
            >
              {MODELS.map(model => (
                <option key={model.id} value={model.id}>
                  {model.provider} - {model.name}
                </option>
              ))}
            </select>
          </div>

          <div style={{ marginTop: 'auto' }}>
            <button
              className="btn btn-outline-dark w-100"
              onClick={() => authService.logout()}
            >
              Logout
            </button>
          </div>
        </div>

        {/* Chat area */}
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
          {/* Messages */}
          <div style={{ flex: 1, overflowY: 'auto', padding: '20px' }}>
            {messages.length === 0 && (
              <div style={{ textAlign: 'center', color: '#6c757d', marginTop: '60px' }}>
                <h5>Welcome to AI Gateway</h5>
                <p>Select a model and start a conversation.</p>
              </div>
            )}

            {messages.map((msg, idx) => (
              <div key={idx} className={`mb-3 ${msg.role === 'user' ? 'text-end' : ''}`}>
                <div
                  className="d-inline-block p-3 rounded"
                  style={{
                    maxWidth: '70%',
                    whiteSpace: 'pre-wrap',
                    backgroundColor: msg.role === 'user' ? '#ED1C24' : (msg.isError ? '#fff3cd' : '#f0f0f0'),
                    color: msg.role === 'user' ? '#FFFFFF' : '#000000'
                  }}
                >
                  {msg.content[0].text || (msg.role === 'assistant' && loading && idx === messages.length - 1 ? '...' : '')}
                </div>
                {/* Token usage display */}
                {msg.usage && (
                  <div style={{ fontSize: '0.75rem', color: '#6c757d', marginTop: '4px' }}>
                    Tokens — Input: {msg.usage.inputTokens} | Output: {msg.usage.outputTokens}
                  </div>
                )}
              </div>
            ))}
            <div ref={messagesEndRef} />
          </div>

          {/* Input area */}
          <div style={{ padding: '20px', borderTop: '1px solid #dee2e6' }}>
            <div className="input-group">
              <input
                type="text"
                className="form-control"
                placeholder="Type your message..."
                value={input}
                onChange={(e) => setInput(e.target.value)}
                onKeyPress={(e) => e.key === 'Enter' && handleSend()}
                disabled={loading}
              />
              <button
                className="btn"
                style={{ backgroundColor: '#ED1C24', color: '#FFFFFF', borderColor: '#ED1C24' }}
                onClick={handleSend}
                disabled={loading}
              >
                {loading ? 'Sending...' : 'Send'}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

export default Chat;
