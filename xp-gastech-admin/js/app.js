// XP GasTech Admin Portal - Main Application Logic

let activeTab = 'overview';
let currentRetailer = null;
let currentTicket = null;
let currentUser = null;
let leafletMap = null;
let miniMap = null;
let miniMapMarker = null;
let mapMarkers = [];

// Initialize on DOM load
document.addEventListener('DOMContentLoaded', () => {
  initAuth();
  initNav();
  initModals();
});

// Toast notification
function showToast(message, type = 'info') {
  const container = document.getElementById('toast-container');
  if (!container) return;

  const toast = document.createElement('div');
  toast.className = `toast toast-${type}`;
  toast.innerHTML = `
    <span>${message}</span>
  `;

  container.appendChild(toast);
  setTimeout(() => {
    toast.style.opacity = '0';
    toast.style.transform = 'translateY(10px)';
    setTimeout(() => toast.remove(), 300);
  }, 3500);
}

// ---------------- AUTHENTICATION ----------------
function initAuth() {
  const authContainer = document.getElementById('auth-container');
  const appContainer = document.getElementById('app-container');
  const loginForm = document.getElementById('login-form');
  const logoutBtn = document.getElementById('btn-logout');

  if (window.api.isAuthenticated()) {
    authContainer.style.display = 'none';
    appContainer.style.display = 'flex';
    setupUserHeader();
    loadTab(activeTab);
  } else {
    authContainer.style.display = 'flex';
    appContainer.style.display = 'none';
  }

  loginForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    const email = document.getElementById('login-email').value;
    const password = document.getElementById('login-password').value;
    const btn = document.getElementById('btn-login-submit');

    btn.disabled = true;
    btn.textContent = 'Authenticating...';

    try {
      await window.api.login(email, password);
      showToast('Welcome back, Admin!', 'success');
      authContainer.style.display = 'none';
      appContainer.style.display = 'flex';
      setupUserHeader();
      loadTab('overview');
    } catch (err) {
      showToast(err.message, 'error');
    } finally {
      btn.disabled = false;
      btn.textContent = 'Sign In to Portal';
    }
  });

  logoutBtn.addEventListener('click', () => {
    window.api.logout();
  });

  window.addEventListener('admin-auth-expired', () => {
    showToast('Session expired. Please sign in again.', 'warning');
    authContainer.style.display = 'flex';
    appContainer.style.display = 'none';
  });
}

function setupUserHeader() {
  const user = window.api.user;
  if (!user) return;
  const avatar = document.getElementById('header-user-avatar');
  const nameEl = document.getElementById('header-user-name');
  if (avatar) avatar.textContent = (user.username || user.email || 'A').slice(0, 2).toUpperCase();
  if (nameEl) nameEl.textContent = user.username || user.email;
}

// ---------------- NAVIGATION ----------------
function initNav() {
  document.querySelectorAll('.nav-item').forEach((item) => {
    item.addEventListener('click', () => {
      const tab = item.getAttribute('data-tab');
      if (tab) {
        document.querySelectorAll('.nav-item').forEach((n) => n.classList.remove('active'));
        item.classList.add('active');
        loadTab(tab);
      }
    });
  });
}

function loadTab(tab) {
  activeTab = tab;
  document.querySelectorAll('.tab-pane').forEach((p) => (p.style.display = 'none'));
  const targetPane = document.getElementById(`pane-${tab}`);
  if (targetPane) targetPane.style.display = 'flex';

  const titles = {
    overview: { title: 'Platform Overview', desc: 'Real-time telemetry, active verification queue, and KPI metrics' },
    stations: { title: 'Gas Plant Verification Queue', desc: 'Review, verify coordinates, and manage nationwide plant locations' },
    map: { title: 'Nationwide Plant Refill Map', desc: 'Interactive geographic view of verified & pending gas plants in Nigeria' },
    users: { title: 'User & Access Governance', desc: 'Manage consumer, retailer, and administrator account roles' },
    meters: { title: 'Digital Meter Telemetry', desc: 'Real-time monitoring of commercial & residential gas cylinders' },
    support: { title: 'Support & Inquiries Desk', desc: 'Customer questions, retailer support, and ticket tracking' },
  };

  const header = titles[tab] || titles.overview;
  document.getElementById('page-title').textContent = header.title;
  document.getElementById('page-desc').textContent = header.desc;

  if (tab === 'overview') loadOverview();
  else if (tab === 'stations') loadStations();
  else if (tab === 'map') loadMap();
  else if (tab === 'users') loadUsers();
  else if (tab === 'meters') loadMeters();
  else if (tab === 'support') loadSupport();
}

// ---------------- TAB 1: OVERVIEW ----------------
async function loadOverview() {
  try {
    const { stats } = await window.api.getStats();

    // Fill KPI numbers
    document.getElementById('kpi-stations-total').textContent = stats.retailers.total;
    document.getElementById('kpi-stations-pending').textContent = stats.retailers.pending;
    document.getElementById('kpi-users-total').textContent = stats.users.total;
    document.getElementById('kpi-meters-active').textContent = stats.meters.active;
    document.getElementById('kpi-support-new').textContent = stats.support.new;

    // Update sidebar badges
    const stationBadge = document.getElementById('sidebar-badge-stations');
    if (stationBadge) {
      stationBadge.textContent = stats.retailers.pending;
      stationBadge.style.display = stats.retailers.pending > 0 ? 'inline-block' : 'none';
    }
    const supportBadge = document.getElementById('sidebar-badge-support');
    if (supportBadge) {
      supportBadge.textContent = stats.support.new;
      supportBadge.style.display = stats.support.new > 0 ? 'inline-block' : 'none';
    }

    // Load recent pending queue
    const { retailers } = await window.api.getRetailers({ status: 'pending', limit: 5 });
    const tbody = document.getElementById('overview-pending-tbody');
    tbody.innerHTML = '';

    if (!retailers || retailers.length === 0) {
      tbody.innerHTML = `<tr><td colspan="6" class="empty-state"><div class="empty-icon">✓</div>No pending gas plants. All submissions have been reviewed!</td></tr>`;
      return;
    }

    retailers.forEach((r) => {
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td><strong>${escapeHtml(r.name)}</strong><br><small class="text-muted">${escapeHtml(r.state || 'N/A')}</small></td>
        <td>${escapeHtml(r.phone || 'N/A')}</td>
        <td>₦${r.pricePerKg ? r.pricePerKg.toLocaleString() : '---'}</td>
        <td><span class="badge badge-pending">Pending Review</span></td>
        <td>${formatDate(r.createdAt)}</td>
        <td>
          <button class="btn btn-primary btn-sm" onclick="inspectRetailer('${r.id}')">Inspect & Verify</button>
        </td>
      `;
      tbody.appendChild(tr);
    });
  } catch (err) {
    showToast(`Failed to load overview: ${err.message}`, 'error');
  }
}

// ---------------- TAB 2: STATIONS ----------------
let currentStationStatus = 'all';
let stationSearchTimeout = null;

async function loadStations() {
  setupStationFilters();
  fetchStationList();
}

function setupStationFilters() {
  document.querySelectorAll('.station-filter-btn').forEach((btn) => {
    btn.onclick = () => {
      document.querySelectorAll('.station-filter-btn').forEach((b) => b.classList.remove('active'));
      btn.classList.add('active');
      currentStationStatus = btn.getAttribute('data-status');
      fetchStationList();
    };
  });

  const searchInput = document.getElementById('station-search-input');
  if (searchInput) {
    searchInput.oninput = () => {
      clearTimeout(stationSearchTimeout);
      stationSearchTimeout = setTimeout(() => {
        fetchStationList();
      }, 300);
    };
  }
}

async function fetchStationList() {
  const tbody = document.getElementById('stations-tbody');
  tbody.innerHTML = `<tr><td colspan="7" class="empty-state">Loading gas plants...</td></tr>`;

  const search = document.getElementById('station-search-input')?.value || '';

  try {
    const { retailers, total } = await window.api.getRetailers({
      status: currentStationStatus,
      search,
      limit: 100,
    });

    document.getElementById('stations-count-label').textContent = `${total} stations registered`;

    tbody.innerHTML = '';
    if (!retailers || retailers.length === 0) {
      tbody.innerHTML = `<tr><td colspan="7" class="empty-state"><div class="empty-icon">🔍</div>No stations found matching criteria.</td></tr>`;
      return;
    }

    retailers.forEach((r) => {
      const tr = document.createElement('tr');
      const badgeClass = r.status === 'approved' ? 'badge-approved' : r.status === 'pending' ? 'badge-pending' : 'badge-rejected';
      const stockBadge = r.isAvailable
        ? '<span style="color:#10b981;font-weight:600">● In Stock</span>'
        : '<span style="color:#ef4444;font-weight:600">● Out of Stock</span>';

      const hoursSummary = formatOpeningHours(r.openingHours);
      tr.innerHTML = `
        <td>
          <strong>${escapeHtml(r.name)}</strong>
          <br><small class="text-muted">${escapeHtml(r.address || '')}, ${escapeHtml(r.state || '')}</small>
          ${hoursSummary ? `<br><small style="color:var(--primary);font-weight:600">🕒 ${escapeHtml(hoursSummary)}</small>` : ''}
        </td>
        <td>${escapeHtml(r.phone || 'N/A')}</td>
        <td><strong>₦${r.pricePerKg ? r.pricePerKg.toLocaleString() : '---'}</strong> / kg</td>
        <td>${stockBadge}</td>
        <td><span class="badge ${badgeClass}">${r.status}</span></td>
        <td>${formatDate(r.createdAt)}</td>
        <td>
          <button class="btn btn-secondary btn-sm" onclick="inspectRetailer('${r.id}')">Review</button>
        </td>
      `;
      tbody.appendChild(tr);
    });
  } catch (err) {
    showToast(`Error loading stations: ${err.message}`, 'error');
  }
}

// Inspect & Verify modal
window.inspectRetailer = async function(id) {
  try {
    const { retailer } = await window.api.getRetailer(id);
    currentRetailer = retailer;

    document.getElementById('modal-station-name').textContent = retailer.name;
    document.getElementById('modal-station-address').textContent = `${retailer.address || ''}, ${retailer.cityLga || ''}, ${retailer.state || ''}`;
    document.getElementById('modal-station-phone').textContent = retailer.phone || 'N/A';
    document.getElementById('modal-station-price').textContent = retailer.pricePerKg ? `₦${retailer.pricePerKg.toLocaleString()} / kg` : 'Not Set';
    document.getElementById('modal-station-about').textContent = retailer.about || 'No description provided by plant manager.';
    document.getElementById('modal-station-owner').textContent = `${retailer.ownerEmail || 'Unknown'} (${retailer.ownerPhone || 'No phone'})`;

    // Calculated refills
    const p = retailer.pricePerKg || 0;
    document.getElementById('calc-6kg').textContent = p ? `₦${(p * 6).toLocaleString()}` : '---';
    document.getElementById('calc-12kg').textContent = p ? `₦${(p * 12.5).toLocaleString()}` : '---';

    // Operating hours
    const hoursEl = document.getElementById('modal-station-hours');
    const formattedHours = formatOpeningHours(retailer.openingHours);
    if (hoursEl) hoursEl.textContent = formattedHours || 'Not set';

    const openInput = document.getElementById('modal-edit-open-time');
    const closeInput = document.getElementById('modal-edit-close-time');
    const sunInput = document.getElementById('modal-edit-open-sunday');
    const sampleSlot = retailer.openingHours?.mon || retailer.openingHours?.tue || retailer.openingHours?.sat;
    if (openInput) openInput.value = sampleSlot?.open || '08:00';
    if (closeInput) closeInput.value = sampleSlot?.close || '20:00';
    if (sunInput) sunInput.checked = retailer.openingHours ? Boolean(retailer.openingHours.sun) : true;

    // WhatsApp / Call links
    const phoneClean = (retailer.phone || '').replace(/[^0-9]/g, '');
    const waBtn = document.getElementById('btn-station-whatsapp');
    const callBtn = document.getElementById('btn-station-call');
    if (phoneClean) {
      waBtn.href = `https://wa.me/${phoneClean}`;
      waBtn.style.display = 'inline-flex';
      callBtn.href = `tel:+${phoneClean}`;
      callBtn.style.display = 'inline-flex';
    } else {
      waBtn.style.display = 'none';
      callBtn.style.display = 'none';
    }

    // Coordinates preview & mini map
    const coordsEl = document.getElementById('modal-station-coords');
    if (retailer.latitude && retailer.longitude) {
      coordsEl.textContent = `${Number(retailer.latitude).toFixed(6)}, ${Number(retailer.longitude).toFixed(6)}`;
      renderMiniMap(retailer.latitude, retailer.longitude, retailer.name);
    } else {
      coordsEl.textContent = 'Coordinates not pinned';
    }

    // Status display & actions
    const statusBadge = document.getElementById('modal-station-status');
    statusBadge.textContent = retailer.status;
    statusBadge.className = `badge ${retailer.status === 'approved' ? 'badge-approved' : retailer.status === 'pending' ? 'badge-pending' : 'badge-rejected'}`;

    openModal('station-modal');
  } catch (err) {
    showToast(`Failed to inspect plant: ${err.message}`, 'error');
  }
};

function renderMiniMap(lat, lng, name) {
  const container = document.getElementById('modal-mini-map');
  if (!container) return;

  if (!miniMap) {
    miniMap = L.map('modal-mini-map').setView([lat, lng], 15);
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '© OpenStreetMap',
    }).addTo(miniMap);
    miniMapMarker = L.marker([lat, lng]).addTo(miniMap);
  } else {
    miniMap.setView([lat, lng], 15);
    miniMapMarker.setLatLng([lat, lng]);
  }
  miniMapMarker.bindPopup(`<b>${escapeHtml(name)}</b><br>Entrance Pin`).openPopup();
  setTimeout(() => miniMap.invalidateSize(), 200);
}

// ---------------- TAB 3: NATIONWIDE REFILL MAP ----------------
async function loadMap() {
  const container = document.getElementById('refill-map');
  if (!container) return;

  if (!leafletMap) {
    // Center over Nigeria
    leafletMap = L.map('refill-map').setView([9.0820, 8.6753], 6);
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '© OpenStreetMap contributors',
    }).addTo(leafletMap);
  }

  setTimeout(() => leafletMap.invalidateSize(), 150);

  // Clear existing markers
  mapMarkers.forEach((m) => leafletMap.removeLayer(m));
  mapMarkers = [];

  try {
    const { retailers } = await window.api.getRetailers({ limit: 200 });

    retailers.forEach((r) => {
      if (!r.latitude || !r.longitude) return;

      const color = r.status === 'approved'
        ? (r.isAvailable ? '#10b981' : '#0284c7')
        : (r.status === 'pending' ? '#f59e0b' : '#ef4444');

      const circle = L.circleMarker([r.latitude, r.longitude], {
        radius: 9,
        fillColor: color,
        color: '#ffffff',
        weight: 2,
        opacity: 1,
        fillOpacity: 0.85,
      }).addTo(leafletMap);

      const hoursStr = formatOpeningHours(r.openingHours);
      circle.bindPopup(`
        <div style="font-family:system-ui;min-width:180px">
          <h4 style="margin:0 0 4px 0;font-size:14px;color:#0f172a">${escapeHtml(r.name)}</h4>
          <p style="margin:0 0 6px 0;font-size:12px;color:#64748b">${escapeHtml(r.address || '')}</p>
          ${hoursStr ? `<p style="margin:0 0 6px 0;font-size:11px;color:#475569;font-weight:600">🕒 ${escapeHtml(hoursStr)}</p>` : ''}
          <div style="margin-bottom:8px">
            <span style="font-weight:700;color:#0053BA">₦${r.pricePerKg ? r.pricePerKg.toLocaleString() : '---'} / kg</span>
            <span style="font-size:11px;padding:2px 6px;border-radius:4px;margin-left:6px;background:${color}22;color:${color};font-weight:700">${r.status}</span>
          </div>
          <button style="width:100%;padding:6px;font-size:12px;background:#0053BA;color:#fff;border:none;border-radius:4px;cursor:pointer;font-weight:600" onclick="inspectRetailer('${r.id}')">Inspect Plant</button>
        </div>
      `);

      mapMarkers.push(circle);
    });
  } catch (err) {
    showToast(`Failed to load stations on map: ${err.message}`, 'error');
  }
}

window.zoomMap = function(lat, lng, zoom = 12) {
  if (leafletMap) {
    leafletMap.flyTo([lat, lng], zoom, { duration: 1.5 });
  }
};

// ---------------- TAB 4: USERS & ROLES ----------------
let currentUserRole = 'all';
let userSearchTimeout = null;

async function loadUsers() {
  document.querySelectorAll('.user-filter-btn').forEach((btn) => {
    btn.onclick = () => {
      document.querySelectorAll('.user-filter-btn').forEach((b) => b.classList.remove('active'));
      btn.classList.add('active');
      currentUserRole = btn.getAttribute('data-role');
      fetchUsersList();
    };
  });

  const searchInput = document.getElementById('user-search-input');
  if (searchInput) {
    searchInput.oninput = () => {
      clearTimeout(userSearchTimeout);
      userSearchTimeout = setTimeout(() => fetchUsersList(), 300);
    };
  }

  fetchUsersList();
}

async function fetchUsersList() {
  const tbody = document.getElementById('users-tbody');
  tbody.innerHTML = `<tr><td colspan="7" class="empty-state">Loading users...</td></tr>`;

  const search = document.getElementById('user-search-input')?.value || '';

  try {
    const { users, total } = await window.api.getUsers({
      role: currentUserRole,
      search,
      limit: 100,
    });

    document.getElementById('users-count-label').textContent = `${total} accounts registered`;
    tbody.innerHTML = '';

    if (!users || users.length === 0) {
      tbody.innerHTML = `<tr><td colspan="7" class="empty-state"><div class="empty-icon">👥</div>No users found.</td></tr>`;
      return;
    }

    users.forEach((u) => {
      const tr = document.createElement('tr');
      const roleBadge = u.role === 'admin'
        ? '<span class="badge badge-role-admin">Admin</span>'
        : u.role === 'retailer'
        ? '<span class="badge badge-role-retailer">Retailer</span>'
        : '<span class="badge badge-role-consumer">Consumer</span>';

      const emailVer = u.emailVerified ? '✓' : '<span style="color:#ef4444">✕</span>';

      tr.innerHTML = `
        <td><strong>${escapeHtml(u.username || '---')}</strong></td>
        <td>${escapeHtml(u.email || 'N/A')}</td>
        <td>${escapeHtml(u.phone || 'N/A')}</td>
        <td>${roleBadge}</td>
        <td>${emailVer}</td>
        <td>${u.stationCount} plants / ${u.meterCount} meters</td>
        <td>
          <button class="btn btn-secondary btn-sm" onclick="editUserRole('${u.id}', '${u.email || u.username}', '${u.role}')">Change Role</button>
        </td>
      `;
      tbody.appendChild(tr);
    });
  } catch (err) {
    showToast(`Error loading users: ${err.message}`, 'error');
  }
}

window.editUserRole = function(id, name, currentRole) {
  currentUser = { id, name, currentRole };
  document.getElementById('modal-role-username').textContent = name;
  document.getElementById('modal-role-select').value = currentRole;
  openModal('user-role-modal');
};

// ---------------- TAB 5: METERS ----------------
const recentDeviceKeys = new Map();

function showDeviceKeyModal({ meterId, btAddress, label, deviceKey }) {
  if (meterId && deviceKey) {
    recentDeviceKeys.set(meterId, deviceKey);
  }
  document.getElementById('device-key-meter-label').textContent = `${label || 'XP Smart Meter'} (${btAddress || meterId})`;
  document.getElementById('device-key-value').value = deviceKey;
  const fwEl = document.getElementById('device-key-firmware');
  if (fwEl) {
    fwEl.textContent =
`const char API_HOST[]   = "api.xptechltd.com";
const uint16_t API_PORT = 443; // HTTPS (Vercel requires TLS on 443)
const char API_PATH[]   = "/api/v1/devices/telemetry";
const char API_TOKEN[]  = "${deviceKey}"; // send in header X-Device-Key`;
  }
  document.getElementById('device-key-curl').textContent =
`curl -X POST https://api.xptechltd.com/api/v1/devices/telemetry \\
  -H "Content-Type: application/json" \\
  -H "X-Device-Key: ${deviceKey}" \\
  -d '{"percent":82,"weightKg":10.25,"battery":94,"leak":0,"rssi":-61}'`;
  openModal('device-key-modal');
}

document.getElementById('btn-copy-firmware-cfg')?.addEventListener('click', async () => {
  const val = document.getElementById('device-key-firmware')?.textContent;
  if (!val) return;
  try {
    await navigator.clipboard.writeText(val);
    showToast('Arduino/IoT firmware config copied', 'success');
  } catch {
    showToast('Copy failed — please select and copy manually', 'error');
  }
});

document.getElementById('btn-copy-device-key')?.addEventListener('click', async () => {
  const val = document.getElementById('device-key-value')?.value;
  if (!val) return;
  try {
    await navigator.clipboard.writeText(val);
    showToast('Hardware X-Device-Key copied to clipboard', 'success');
  } catch {
    showToast('Copy failed — please select and copy manually', 'error');
  }
});

document.getElementById('btn-gen-mac')?.addEventListener('click', () => {
  const bytes = Array.from({ length: 6 }, () =>
    Math.floor(Math.random() * 256).toString(16).padStart(2, '0').toUpperCase()
  );
  document.getElementById('prov-bt-address').value = bytes.join(':');
});

document.getElementById('btn-open-provision-meter')?.addEventListener('click', async () => {
  const select = document.getElementById('prov-owner-id');
  openModal('provision-meter-modal');
  if (select) {
    select.innerHTML = '<option value="">Loading accounts...</option>';
    try {
      const { users } = await window.api.getUsers({ limit: 100 });
      const currentId = window.api.user?.id || '';
      select.innerHTML = (users || []).map((u) => {
        const label = `${escapeHtml(u.email || u.username || u.phone || u.id)} (${escapeHtml(u.role)})`;
        return `<option value="${escapeHtml(u.id)}"${u.id === currentId ? ' selected' : ''}>${label}</option>`;
      }).join('') || `<option value="${escapeHtml(currentId)}">Current Admin</option>`;
    } catch {
      const currentId = window.api.user?.id || '';
      select.innerHTML = `<option value="${escapeHtml(currentId)}">Current Admin (${escapeHtml(window.api.user?.email || 'me')})</option>`;
    }
  }
});

document.getElementById('btn-confirm-provision-meter')?.addEventListener('click', async () => {
  const ownerUserId = document.getElementById('prov-owner-id').value.trim() || undefined;
  const btAddress = document.getElementById('prov-bt-address').value.trim();
  const label = document.getElementById('prov-label').value.trim();
  const cylinderSizeKg = Number(document.getElementById('prov-size').value) || 12.5;
  if (!btAddress) {
    showToast('Device MAC / Serial Address is required', 'error');
    return;
  }
  try {
    const res = await window.api.provisionMeter({ ownerUserId, btAddress, label, cylinderSizeKg, generateKey: true });
    closeModal();
    showToast('Meter provisioned', 'success');
    if (res.deviceKey) {
      showDeviceKeyModal({
        meterId: res.meter.id,
        btAddress: res.meter.btAddress,
        label: res.meter.label,
        deviceKey: res.deviceKey,
      });
    }
    loadMeters();
  } catch (err) {
    showToast(`Provision failed: ${err.message}`, 'error');
  }
});

async function loadMeters() {
  const tbody = document.getElementById('meters-tbody');
  tbody.innerHTML = `<tr><td colspan="9" class="empty-state">Loading digital meter readings...</td></tr>`;

  try {
    const { meters } = await window.api.getMeters();
    tbody.innerHTML = '';

    if (!meters || meters.length === 0) {
      tbody.innerHTML = `<tr><td colspan="9" class="empty-state"><div class="empty-icon">📟</div>No registered digital meters in system yet.</td></tr>`;
      return;
    }

    meters.forEach((m) => {
      const tr = document.createElement('tr');
      const reading = m.latestReading;
      const percent = reading?.percent ?? 0;
      const barClass = percent > 40 ? 'high' : percent > 15 ? 'medium' : 'low';

      const leakStatus = reading?.leakLevel === 0
        ? '<span style="color:#10b981;font-weight:700">● Safe</span>'
        : (reading?.leakLevel ? '<span style="color:#ef4444;font-weight:700">⚠ LEAK DETECTED</span>' : '<span class="text-muted">No telemetry</span>');

      const keyBadge = m.hasDeviceKey
        ? '<span style="color:#10b981;font-weight:700;font-size:12px;">● Key Active</span>'
        : '<span style="color:#64748b;font-size:12px;">○ No Key</span>';

      const cachedKey = recentDeviceKeys.get(m.id);
      tr.innerHTML = `
        <td><code>${escapeHtml(m.btAddress)}</code><br><small class="text-muted">${escapeHtml(m.label || 'Default Cylinder')}${m.firmwareVersion ? ` · v${escapeHtml(m.firmwareVersion)}` : ''}</small></td>
        <td>${escapeHtml(m.ownerEmail || 'Unknown')}</td>
        <td>${m.cylinderSizeKg ? `${m.cylinderSizeKg} kg` : '12.5 kg'}</td>
        <td>
          <div class="gas-bar-wrapper">
            <div class="gas-bar-track">
              <div class="gas-bar-fill ${barClass}" style="width:${Math.min(100, percent)}%"></div>
            </div>
            <strong>${percent}%</strong>
          </div>
        </td>
        <td>${reading?.weightKg !== null && reading?.weightKg !== undefined ? `${reading.weightKg} kg` : '---'}</td>
        <td>${reading?.battery !== null && reading?.battery !== undefined ? `${reading.battery}%` : '---'}</td>
        <td>${leakStatus}</td>
        <td>${m.lastReadingAt ? formatDate(m.lastReadingAt) : 'Never'}</td>
        <td>
          <div style="display:flex;flex-direction:column;gap:6px;align-items:flex-start;">
            ${keyBadge}
            <div style="display:flex;gap:6px;flex-wrap:wrap;">
              ${cachedKey ? '<button class="btn btn-primary btn-sm btn-show-key">View / Copy Key</button>' : ''}
              <button class="btn ${cachedKey ? 'btn-secondary' : 'btn-primary'} btn-sm btn-gen-key">${m.hasDeviceKey ? 'Rotate Key' : 'Generate Key'}</button>
              ${m.hasDeviceKey ? '<button class="btn btn-secondary btn-sm btn-revoke-key">Revoke</button>' : ''}
              <button class="btn btn-secondary btn-sm btn-ping-meter" title="Queue PING command">Ping</button>
            </div>
          </div>
        </td>
      `;

      tr.querySelector('.btn-show-key')?.addEventListener('click', () => {
        showDeviceKeyModal({
          meterId: m.id,
          btAddress: m.btAddress,
          label: m.label,
          deviceKey: cachedKey,
        });
      });

      tr.querySelector('.btn-gen-key')?.addEventListener('click', async () => {
        if (m.hasDeviceKey && !confirm(`Rotate X-Device-Key for ${m.btAddress}? The old hardware key will stop working immediately.`)) return;
        try {
          const res = await window.api.generateMeterDeviceKey(m.id);
          showDeviceKeyModal(res);
          loadMeters();
        } catch (err) {
          showToast(`Key generation failed: ${err.message}`, 'error');
        }
      });

      tr.querySelector('.btn-revoke-key')?.addEventListener('click', async () => {
        if (!confirm(`Revoke X-Device-Key for ${m.btAddress}?`)) return;
        try {
          await window.api.revokeMeterDeviceKey(m.id);
          showToast('Hardware key revoked', 'success');
          loadMeters();
        } catch (err) {
          showToast(`Revoke failed: ${err.message}`, 'error');
        }
      });

      tr.querySelector('.btn-ping-meter')?.addEventListener('click', async () => {
        try {
          await window.api.sendMeterCommand(m.id, 'PING');
          showToast(`PING command queued for ${m.btAddress}`, 'success');
        } catch (err) {
          showToast(`Command failed: ${err.message}`, 'error');
        }
      });

      tbody.appendChild(tr);
    });
  } catch (err) {
    showToast(`Error loading meters: ${err.message}`, 'error');
  }
}

// ---------------- TAB 6: SUPPORT DESK ----------------
let currentSupportStatus = 'all';

async function loadSupport() {
  document.querySelectorAll('.support-filter-btn').forEach((btn) => {
    btn.onclick = () => {
      document.querySelectorAll('.support-filter-btn').forEach((b) => b.classList.remove('active'));
      btn.classList.add('active');
      currentSupportStatus = btn.getAttribute('data-status');
      fetchSupportList();
    };
  });

  fetchSupportList();
}

async function fetchSupportList() {
  const tbody = document.getElementById('support-tbody');
  tbody.innerHTML = `<tr><td colspan="7" class="empty-state">Loading support inquiries...</td></tr>`;

  try {
    const { inquiries } = await window.api.getSupport({
      status: currentSupportStatus,
      limit: 100,
    });

    tbody.innerHTML = '';
    if (!inquiries || inquiries.length === 0) {
      tbody.innerHTML = `<tr><td colspan="7" class="empty-state"><div class="empty-icon">📨</div>No support tickets in this view.</td></tr>`;
      return;
    }

    inquiries.forEach((item) => {
      const tr = document.createElement('tr');
      const badgeClass = item.status === 'new' ? 'badge-pending' : item.status === 'in_progress' ? 'badge-role-retailer' : 'badge-approved';

      tr.innerHTML = `
        <td>${formatDate(item.createdAt)}</td>
        <td><strong>${escapeHtml(item.name)}</strong></td>
        <td>${escapeHtml(item.email || item.phone || 'N/A')}</td>
        <td><span class="badge" style="background:#f1f5f9">${escapeHtml(item.category)}</span></td>
        <td><strong>${escapeHtml(item.subject)}</strong></td>
        <td><span class="badge ${badgeClass}">${item.status}</span></td>
        <td>
          <button class="btn btn-secondary btn-sm" onclick="openSupportTicket('${item.id}')">Manage</button>
        </td>
      `;
      tbody.appendChild(tr);
    });
  } catch (err) {
    showToast(`Error loading support tickets: ${err.message}`, 'error');
  }
}

window.openSupportTicket = async function(id) {
  try {
    const { inquiries } = await window.api.getSupport({ limit: 100 });
    const item = inquiries.find((x) => x.id === id);
    if (!item) return;

    currentTicket = item;
    document.getElementById('ticket-name').textContent = item.name;
    document.getElementById('ticket-contact').textContent = `${item.email || ''} ${item.phone ? '• ' + item.phone : ''}`;
    document.getElementById('ticket-subject').textContent = item.subject;
    document.getElementById('ticket-message').textContent = item.message;
    document.getElementById('ticket-status-select').value = item.status;
    document.getElementById('ticket-notes').value = item.adminNotes || '';

    const waBtn = document.getElementById('btn-ticket-whatsapp');
    const mailBtn = document.getElementById('btn-ticket-email');
    if (item.phone) {
      waBtn.href = `https://wa.me/${item.phone.replace(/[^0-9]/g, '')}`;
      waBtn.style.display = 'inline-flex';
    } else {
      waBtn.style.display = 'none';
    }
    if (item.email) {
      mailBtn.href = `mailto:${item.email}?subject=RE: ${encodeURIComponent(item.subject)}`;
      mailBtn.style.display = 'inline-flex';
    } else {
      mailBtn.style.display = 'none';
    }

    openModal('support-modal');
  } catch (err) {
    showToast(`Failed to open ticket: ${err.message}`, 'error');
  }
};

// ---------------- MODAL INITIALIZATIONS & ACTIONS ----------------
function initModals() {
  // Close buttons
  document.querySelectorAll('.btn-close, .modal-close-trigger').forEach((btn) => {
    btn.onclick = () => closeModal();
  });

  // Save Operating Hours
  document.getElementById('btn-save-station-hours')?.addEventListener('click', async () => {
    if (!currentRetailer) return;
    const open = document.getElementById('modal-edit-open-time')?.value || '08:00';
    const close = document.getElementById('modal-edit-close-time')?.value || '20:00';
    const openSun = document.getElementById('modal-edit-open-sunday')?.checked ?? true;
    const slot = { open, close };
    const openingHours = {
      mon: slot, tue: slot, wed: slot, thu: slot, fri: slot, sat: slot,
      sun: openSun ? slot : null,
    };

    try {
      const { retailer } = await window.api.updateRetailer(currentRetailer.id, { openingHours });
      currentRetailer = retailer;
      document.getElementById('modal-station-hours').textContent = formatOpeningHours(retailer.openingHours) || 'Updated';
      showToast('Operating hours saved!', 'success');
      if (activeTab === 'stations') fetchStationList();
    } catch (err) {
      showToast(`Failed to save hours: ${err.message}`, 'error');
    }
  });

  // Review Plant Actions
  document.getElementById('btn-approve-plant')?.addEventListener('click', async () => {
    if (!currentRetailer) return;
    try {
      await window.api.reviewRetailer(currentRetailer.id, 'approved');
      showToast(`Plant "${currentRetailer.name}" approved and live on map!`, 'success');
      closeModal();
      if (activeTab === 'overview') loadOverview();
      else if (activeTab === 'stations') fetchStationList();
      else if (activeTab === 'map') loadMap();
    } catch (err) {
      showToast(err.message, 'error');
    }
  });

  document.getElementById('btn-reject-plant')?.addEventListener('click', async () => {
    if (!currentRetailer) return;
    const reason = prompt('Please enter rejection reason to be sent to applicant:', 'Inaccurate plant coordinates or unverifiable gas license.');
    if (!reason) return;

    try {
      await window.api.reviewRetailer(currentRetailer.id, 'rejected', reason);
      showToast(`Plant "${currentRetailer.name}" marked as rejected.`, 'info');
      closeModal();
      if (activeTab === 'overview') loadOverview();
      else if (activeTab === 'stations') fetchStationList();
      else if (activeTab === 'map') loadMap();
    } catch (err) {
      showToast(err.message, 'error');
    }
  });

  document.getElementById('btn-delete-plant')?.addEventListener('click', async () => {
    if (!currentRetailer) return;
    if (!confirm(`Are you sure you want to permanently delete "${currentRetailer.name}"?`)) return;

    try {
      await window.api.deleteRetailer(currentRetailer.id);
      showToast('Station removed successfully.', 'success');
      closeModal();
      if (activeTab === 'overview') loadOverview();
      else if (activeTab === 'stations') fetchStationList();
    } catch (err) {
      showToast(err.message, 'error');
    }
  });

  // User Role Save
  document.getElementById('btn-save-role')?.addEventListener('click', async () => {
    if (!currentUser) return;
    const newRole = document.getElementById('modal-role-select').value;
    try {
      await window.api.updateUserRole(currentUser.id, newRole);
      showToast(`User role updated to ${newRole}`, 'success');
      closeModal();
      fetchUsersList();
    } catch (err) {
      showToast(err.message, 'error');
    }
  });

  // Support Ticket Save
  document.getElementById('btn-save-ticket')?.addEventListener('click', async () => {
    if (!currentTicket) return;
    const status = document.getElementById('ticket-status-select').value;
    const adminNotes = document.getElementById('ticket-notes').value;

    try {
      await window.api.updateSupport(currentTicket.id, { status, adminNotes });
      showToast('Support ticket updated successfully.', 'success');
      closeModal();
      fetchSupportList();
    } catch (err) {
      showToast(err.message, 'error');
    }
  });
}

function openModal(id) {
  document.querySelectorAll('.modal-overlay').forEach((m) => m.classList.remove('active'));
  const modal = document.getElementById(id);
  if (modal) modal.classList.add('active');
}

function closeModal() {
  document.querySelectorAll('.modal-overlay').forEach((m) => m.classList.remove('active'));
}

// ---------------- HELPERS ----------------
function escapeHtml(str) {
  if (!str) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function formatDate(isoStr) {
  if (!isoStr) return '---';
  const d = new Date(isoStr);
  return d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
}

function fmt12h(hhmm) {
  if (!hhmm || !hhmm.includes(':')) return hhmm || '';
  const [hStr, mStr] = hhmm.split(':');
  const h = parseInt(hStr, 10);
  if (Number.isNaN(h)) return hhmm;
  const suffix = h >= 12 ? 'PM' : 'AM';
  const h12 = h === 0 ? 12 : (h > 12 ? h - 12 : h);
  return `${h12}:${mStr} ${suffix}`;
}

function formatOpeningHours(hours) {
  if (!hours || typeof hours !== 'object') return null;
  const days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  const entries = [];
  for (const d of days) {
    const val = hours[d];
    if (val && val.open && val.close) {
      entries.push({ d, text: `${fmt12h(val.open)} – ${fmt12h(val.close)}` });
    }
  }
  if (entries.length === 0) return null;
  const unique = [...new Set(entries.map((e) => e.text))];
  if (unique.length === 1) {
    const range = unique[0];
    const hasSun = entries.some((e) => e.d === 'sun');
    if (entries.length === 7) return `Daily: ${range}`;
    if (entries.length === 6 && !hasSun) return `Mon–Sat: ${range}`;
    return range;
  }
  return entries[0].text;
}
