import React from 'react';
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import Login from './components/Login';
import Callback from './components/Callback';
import Chat from './components/Chat';
import authService from './services/authService';
import 'bootstrap/dist/css/bootstrap.min.css';
import './App.css';

function PrivateRoute({ children }) {
  return authService.isAuthenticated() ? children : <Navigate to="/" />;
}

function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Login />} />
        <Route path="/callback" element={<Callback />} />
        <Route path="/chat" element={<PrivateRoute><Chat /></PrivateRoute>} />
      </Routes>
    </BrowserRouter>
  );
}

export default App;
