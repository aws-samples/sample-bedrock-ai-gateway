import React, { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import authService from '../services/authService';
import Header from './Header';

function Callback() {
  const navigate = useNavigate();
  const [error, setError] = useState(null);

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const code = params.get('code');
    const oauthError = params.get('error');
    const errorDescription = params.get('error_description');

    if (oauthError) {
      let userMessage = 'Authentication failed. Please try again.';

      if (oauthError === 'access_denied') {
        userMessage = 'Access denied. You do not have permission to access this application.';
      } else if (oauthError === 'invalid_grant') {
        userMessage = 'Authentication session expired. Please try logging in again.';
      } else if (oauthError === 'invalid_request') {
        userMessage = 'Invalid authentication request. Please contact your administrator.';
      } else if (errorDescription) {
        userMessage = `Authentication error: ${errorDescription}`;
      }

      setError(userMessage);
      return;
    }

    if (code) {
      authService.handleCallback(code)
        .then(() => navigate('/chat'))
        .catch(err => {
          console.error('Auth error:', err);
          let userMessage = 'An error occurred during authentication.';

          if (err.message.includes('Token exchange failed')) {
            userMessage = 'Failed to complete authentication. Please try logging in again.';
          } else if (err.message.includes('Code verifier not found')) {
            userMessage = 'Authentication session lost. Please try logging in again.';
          } else if (err.message.includes('Network') || err.message.includes('fetch')) {
            userMessage = 'Network error: Unable to connect to authentication service.';
          } else {
            userMessage = err.message;
          }

          setError(userMessage);
        });
    } else {
      navigate('/');
    }
  }, [navigate]);

  if (error) {
    return (
      <>
        <Header />
        <div className="container mt-5">
          <div className="alert alert-danger" role="alert">
            <h4 className="alert-heading">Authentication Error</h4>
            <p>{error}</p>
            <hr />
            <a href="/" className="btn btn-primary mt-2">Back to Login</a>
          </div>
        </div>
      </>
    );
  }

  return (
    <>
      <Header />
      <div className="container text-center mt-5">
        <div className="spinner-border text-danger" role="status">
          <span className="visually-hidden">Loading...</span>
        </div>
        <p className="mt-3">Authenticating...</p>
      </div>
    </>
  );
}

export default Callback;
