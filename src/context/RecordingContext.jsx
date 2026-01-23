import React, { createContext, useState, useCallback } from 'react';

export const RecordingContext = createContext();

export function RecordingProvider({ children }) {
  const [isRecording, setIsRecording] = useState(false);

  const startRecording = useCallback(() => {
    console.log('[RecordingContext] Recording started');
    setIsRecording(true);
  }, []);

  const stopRecording = useCallback(() => {
    console.log('[RecordingContext] Recording stopped');
    setIsRecording(false);
  }, []);

  const value = {
    isRecording,
    startRecording,
    stopRecording,
  };

  return (
    <RecordingContext.Provider value={value}>
      {children}
    </RecordingContext.Provider>
  );
}

export function useRecording() {
  const context = React.useContext(RecordingContext);
  if (!context) throw new Error('useRecording must be used within RecordingProvider');
  return context;
}
