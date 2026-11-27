// XP GasTech Admin API Client
const API_BASE = 'https://api.xptechltd.com';

class AdminApiClient {
  constructor() {
    this.token = localStorage.getItem('xp_admin_token') || null;
    this.user = this._loadUser();
  }

  _loadUser() {
    try {
      const raw = localStorage.getItem('xp_admin_user');
      return raw ? JSON.parse(raw) : null;
    } catch (_) {
      return null;
    }
  }

  isAuthenticated() {
    return Boolean(this.token && this.user && this.user.role === 'admin');
  }

  async login(email, password) {
    const res = await fetch(`${API_BASE}/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: email.trim(), password }),
    });

    const data = await res.json();
    if (!res.ok) {
      throw new Error(data.error || 'Login failed. Please check your credentials.');
    }

    const token = data.tokens?.accessToken || data.token;
    if (!token) {
      throw new Error('Authentication succeeded but no token was provided.');
    }

    // Verify admin access against the live backend
    const checkRes = await fetch(`${API_BASE}/admin/stats`, {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`,
      },
    });

    if (!checkRes.ok) {
      throw new Error('Access denied. This portal is restricted to platform administrators.');
    }

    this.token = token;
    this.user = {
      ...(data.user || {}),
      role: 'admin',
    };

    localStorage.setItem('xp_admin_token', this.token);
    localStorage.setItem('xp_admin_user', JSON.stringify(this.user));

    return { user: this.user, token: this.token };
  }

  logout() {
    this.token = null;
    this.user = null;
    localStorage.removeItem('xp_admin_token');
    localStorage.removeItem('xp_admin_user');
    window.location.reload();
  }

  async _request(endpoint, options = {}) {
    const headers = {
      'Content-Type': 'application/json',
      ...options.headers,
    };

    if (this.token) {
      headers['Authorization'] = `Bearer ${this.token}`;
    }

    const res = await fetch(`${API_BASE}${endpoint}`, {
      ...options,
      headers,
    });

    if (res.status === 401) {
      // Token expired or invalid
      this.token = null;
      this.user = null;
      localStorage.removeItem('xp_admin_token');
      localStorage.removeItem('xp_admin_user');
      window.dispatchEvent(new CustomEvent('admin-auth-expired'));
      throw new Error('Session expired. Please sign in again.');
    }

    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      throw new Error(data.error || `Request failed with status ${res.status}`);
    }

    return data;
  }

  // Dashboard Overview & Stats
  async getStats() {
    return this._request('/admin/stats');
  }

  // Gas Stations / Retailers
  async getRetailers({ status = 'all', search = '', limit = 50, offset = 0 } = {}) {
    const params = new URLSearchParams();
    if (status && status !== 'all') params.set('status', status);
    if (search) params.set('search', search);
    params.set('limit', limit);
    params.set('offset', offset);
    return this._request(`/admin/retailers?${params.toString()}`);
  }

  async getRetailer(id) {
    return this._request(`/admin/retailers/${id}`);
  }

  async updateRetailer(id, updates) {
    return this._request(`/admin/retailers/${id}`, {
      method: 'PATCH',
      body: JSON.stringify(updates),
    });
  }

  async reviewRetailer(id, decision, reason = null) {
    return this._request(`/retailers/${id}/review`, {
      method: 'POST',
      body: JSON.stringify({ decision, reason }),
    });
  }

  async deleteRetailer(id) {
    return this._request(`/admin/retailers/${id}`, {
      method: 'DELETE',
    });
  }

  // Users & Role Management
  async getUsers({ role = 'all', search = '', limit = 50, offset = 0 } = {}) {
    const params = new URLSearchParams();
    if (role && role !== 'all') params.set('role', role);
    if (search) params.set('search', search);
    params.set('limit', limit);
    params.set('offset', offset);
    return this._request(`/admin/users?${params.toString()}`);
  }

  async updateUserRole(id, role) {
    return this._request(`/admin/users/${id}/role`, {
      method: 'PATCH',
      body: JSON.stringify({ role }),
    });
  }

  // Smart Gas Meters
  async getMeters() {
    return this._request('/admin/meters');
  }

  async provisionMeter({ ownerUserId, btAddress, label, cylinderSizeKg, generateKey = true }) {
    return this._request('/admin/meters', {
      method: 'POST',
      body: JSON.stringify({ ownerUserId, btAddress, label, cylinderSizeKg, generateKey }),
    });
  }

  async generateMeterDeviceKey(id) {
    return this._request(`/admin/meters/${id}/device-key`, {
      method: 'POST',
    });
  }

  async revokeMeterDeviceKey(id) {
    return this._request(`/admin/meters/${id}/device-key`, {
      method: 'DELETE',
    });
  }

  async sendMeterCommand(id, command, payload = {}) {
    return this._request(`/admin/meters/${id}/commands`, {
      method: 'POST',
      body: JSON.stringify({ command, payload }),
    });
  }

  // Customer & Business Support Desk
  async getSupport({ status = 'all', search = '', limit = 50, offset = 0 } = {}) {
    const params = new URLSearchParams();
    if (status && status !== 'all') params.set('status', status);
    if (search) params.set('search', search);
    params.set('limit', limit);
    params.set('offset', offset);
    return this._request(`/admin/support?${params.toString()}`);
  }

  async updateSupport(id, { status, adminNotes }) {
    return this._request(`/admin/support/${id}`, {
      method: 'PATCH',
      body: JSON.stringify({ status, adminNotes }),
    });
  }
}

window.api = new AdminApiClient();
