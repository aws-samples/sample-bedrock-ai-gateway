import authService from './authService';

const bedrockService = {
  async sendMessageStream(modelId, messages, onChunk) {
    const { API_GATEWAY_URL } = window.CONFIG;
    const token = authService.getToken();

    // Filter out messages with empty content
    const validMessages = messages.filter(msg =>
      msg.content &&
      msg.content.length > 0 &&
      msg.content[0].text &&
      msg.content[0].text.trim() !== ''
    );

    const response = await fetch(`${API_GATEWAY_URL}/model/${modelId}/converse-stream`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
        'x-api-key': window.CONFIG.API_KEY
      },
      body: JSON.stringify({ messages: validMessages })
    });

    if (!response.ok) {
      if (response.status === 401 || response.status === 403) {
        authService.login();
        return;
      }
      if (response.status === 429) {
        // Try to read the actual error from the response body — the Lambda returns
        // a JSON body with an "error" field that distinguishes budget enforcement
        // from API Gateway rate limiting.
        try {
          const body = await response.json();
          const msg = body.error || '';
          if (msg.toLowerCase().includes('budget')) {
            throw new Error(`BUDGET_EXCEEDED: ${msg}`);
          }
        } catch (parseErr) {
          if (parseErr.message.startsWith('BUDGET_EXCEEDED:')) throw parseErr;
        }
        throw new Error('Rate limit exceeded. Please wait 30-60 seconds before trying again.');
      }
      throw new Error(`API error: ${response.status}`);
    }

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\n');
      buffer = lines.pop();

      for (const line of lines) {
        if (line.startsWith('data: ')) {
          const data = line.slice(6);
          if (data === '[DONE]') continue;

          try {
            const parsed = JSON.parse(data);
            if (parsed.contentBlockDelta?.delta?.text) {
              onChunk(parsed.contentBlockDelta.delta.text);
            }
          } catch (e) {
            console.warn('Failed to parse chunk:', e);
          }
        }
      }
    }
  }
};

export default bedrockService;
