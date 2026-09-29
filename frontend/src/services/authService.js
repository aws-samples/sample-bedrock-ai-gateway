const authService = {
  generateCodeVerifier() {
    const array = new Uint8Array(32);
    crypto.getRandomValues(array);
    return btoa(String.fromCharCode(...array))
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=/g, '');
  },

  async generateCodeChallenge(verifier) {
    const encoder = new TextEncoder();
    const data = encoder.encode(verifier);
    const hash = await crypto.subtle.digest('SHA-256', data);
    return btoa(String.fromCharCode(...new Uint8Array(hash)))
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=/g, '');
  },

  async login() {
    const { COGNITO_DOMAIN, COGNITO_CLIENT_ID, COGNITO_REDIRECT_URI } = window.CONFIG;

    const codeVerifier = this.generateCodeVerifier();
    const codeChallenge = await this.generateCodeChallenge(codeVerifier);

    sessionStorage.setItem('code_verifier', codeVerifier);

    const authUrl = `${COGNITO_DOMAIN}/oauth2/authorize?` +
      `client_id=${COGNITO_CLIENT_ID}&` +
      `response_type=code&` +
      `scope=openid+profile+email&` +
      `redirect_uri=${encodeURIComponent(COGNITO_REDIRECT_URI)}&` +
      `code_challenge=${codeChallenge}&` +
      `code_challenge_method=S256`;

    window.location.href = authUrl;
  },

  async handleCallback(code) {
    const { COGNITO_DOMAIN, COGNITO_CLIENT_ID, COGNITO_REDIRECT_URI } = window.CONFIG;
    const tokenUrl = `${COGNITO_DOMAIN}/oauth2/token`;
    const codeVerifier = sessionStorage.getItem('code_verifier');

    if (!codeVerifier) throw new Error('Code verifier not found');

    const params = new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: COGNITO_CLIENT_ID,
      code: code,
      redirect_uri: COGNITO_REDIRECT_URI,
      code_verifier: codeVerifier
    });

    const response = await fetch(tokenUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: params
    });

    if (!response.ok) throw new Error('Token exchange failed');

    const data = await response.json();
    sessionStorage.removeItem('code_verifier');

    localStorage.setItem('access_token', data.access_token);
    localStorage.setItem('id_token', data.id_token);
    return data;
  },

  getToken() {
    return localStorage.getItem('id_token');
  },

  isAuthenticated() {
    return !!this.getToken();
  },

  logout() {
    const { COGNITO_DOMAIN, COGNITO_CLIENT_ID, COGNITO_LOGOUT_URI } = window.CONFIG;
    localStorage.removeItem('access_token');
    localStorage.removeItem('id_token');
    sessionStorage.clear();
    window.location.href = `${COGNITO_DOMAIN}/logout?client_id=${COGNITO_CLIENT_ID}&logout_uri=${encodeURIComponent(COGNITO_LOGOUT_URI)}`;
  }
};

export default authService;
