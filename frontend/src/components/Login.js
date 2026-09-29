import React from 'react';
import authService from '../services/authService';
import Header from './Header';

function Login() {
  return (
    <>
      <Header />
      <div className="container">
        <div className="row justify-content-center mt-5">
          <div className="col-md-6">
            <div className="card shadow">
              <div className="card-body text-center p-5">
                <h2 className="mb-4">AI Gateway</h2>
                <p className="text-muted mb-4">Sign in to access the AI Gateway</p>
                <button
                  className="btn btn-primary btn-lg"
                  onClick={() => authService.login()}
                >
                  Sign In
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </>
  );
}

export default Login;
