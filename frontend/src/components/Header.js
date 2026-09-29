import React from 'react';
import authService from '../services/authService';

function Header() {
  const isLoggedIn = authService.isAuthenticated();

  return (
    <div className="app-header">
      <div className="container d-flex align-items-center justify-content-between">
        <span className="app-header-title">AI Gateway</span>
        {isLoggedIn && (
          <button
            className="btn btn-outline-light btn-sm"
            onClick={() => authService.logout()}
          >
            Logout
          </button>
        )}
      </div>
    </div>
  );
}

export default Header;
