import React, { createContext, useState, useCallback } from 'react';

export const NotificationContext = createContext();

export function NotificationProvider({ children }) {
  const [pendingEmergency, setPendingEmergency] = useState(null);

  const setEmergency = useCallback((emergencyData) => {
    console.log('[NotificationContext] Setting pending emergency:', emergencyData?.request_id);
    setPendingEmergency(emergencyData);
  }, []);

  const clearEmergency = useCallback(() => {
    console.log('[NotificationContext] Clearing pending emergency');
    setPendingEmergency(null);
  }, []);

  const value = {
    pendingEmergency,
    setEmergency,
    clearEmergency,
  };

  return (
    <NotificationContext.Provider value={value}>
      {children}
    </NotificationContext.Provider>
  );
}

export function useNotification() {
  const context = React.useContext(NotificationContext);
  if (!context) throw new Error('useNotification must be used within NotificationProvider');
  return context;
}
