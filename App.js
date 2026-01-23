import React, { useRef, useEffect, useState } from "react";
import { NavigationContainer } from "@react-navigation/native";
import { createNativeStackNavigator } from "@react-navigation/native-stack";
import { StatusBar } from "expo-status-bar";
import * as Notifications from 'expo-notifications';
import { Linking, ActivityIndicator, View, Text, Alert, AppState, Modal, TouchableOpacity, StyleSheet } from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { Ionicons } from '@expo/vector-icons';
import messaging from '@react-native-firebase/messaging';
import supabase from './src/lib/supabase';

import { AuthProvider, useAuth } from "./src/context/AuthContext";
import { NotificationProvider, useNotification } from "./src/context/NotificationContext";
import { RecordingProvider, useRecording } from "./src/context/RecordingContext";

import LoadingScreen from "./src/screens/LoadingScreen";
import LoginScreen from "./src/screens/LoginScreen";
import ForgotPasswordScreen from "./src/screens/ForgotPasswordScreen";
import CreateNewPasswordScreen from "./src/screens/CreateNewPasswordScreen";
import HomeScreen from "./src/screens/HomeScreen";
import RecordingScreen from "./src/screens/RecordingScreen";
import IncidentSummaryScreen from "./src/screens/IncidentSummaryScreen";
import MyIncidentScreen from "./src/screens/MyIncidentScreen";
import IncidentDetailsScreen from "./src/screens/IncidentDetailsScreen";
import DeviceWelcomeScreen from "./src/screens/DeviceWelcomeScreen";
import DevicePairingFlowScreen from "./src/screens/DevicePairingFlowScreen";
import RequestBackupScreen from "./src/screens/RequestBackupScreen";
import EmergencyBackupScreen from "./src/screens/EmergencyBackupScreen";

const Stack = createNativeStackNavigator();

// Deep linking configuration - kept for future use but not currently used for password reset
const linking = {
  prefixes: ['evvos://'],
  config: {
    screens: {
      // Add other deep link screens here if needed
    },
  },
};

function AppNavigator({ navigationRef }) {
  const { recoveryMode, isAuthenticated, loading } = useAuth();

  // Navigate to password reset screen when recovery mode is detected
  useEffect(() => {
    if (recoveryMode) {
      console.log('Recovery mode detected, navigating to CreateNewPassword');
      navigationRef.current?.navigate('CreateNewPassword');
    }
  }, [recoveryMode, navigationRef]);

  // Screen names that should prevent back navigation
  const screensWithBackDisabled = [
    'Loading',
    'Login',
    'Home',
    'Recording',
    'IncidentSummary',
  ];

  return (
    <NavigationContainer
      ref={navigationRef}
      linking={linking}
      onReady={() => {
        // Add listener to prevent back navigation on specific screens
        if (navigationRef.current) {
          navigationRef.current.addListener('beforeRemove', (e) => {
            const currentRoute = navigationRef.current?.getCurrentRoute();
            
            if (screensWithBackDisabled.includes(currentRoute?.name)) {
              console.log(`[Navigation] Back prevented on screen: ${currentRoute?.name}`);
              e.preventDefault();
            }
          });
        }
      }}
    >
      <StatusBar style="light" />
      <Stack.Navigator initialRouteName="Loading" screenOptions={{ headerShown: false }}>
        <Stack.Screen name="Loading" component={LoadingScreen} options={{ gestureEnabled: false }} />
        <Stack.Screen name="Login" component={LoginScreen} options={{ gestureEnabled: false }} />
        <Stack.Screen name="ForgotPassword" component={ForgotPasswordScreen} />
        <Stack.Screen name="CreateNewPassword" component={CreateNewPasswordScreen} />
        <Stack.Screen name="Home" component={HomeScreen} options={{ gestureEnabled: false }} />
        <Stack.Screen name="Recording" component={RecordingScreen} options={{ gestureEnabled: false }} />
        <Stack.Screen name="IncidentSummary" component={IncidentSummaryScreen} options={{ gestureEnabled: false }} />
        <Stack.Screen name="MyIncident" component={MyIncidentScreen} />
        <Stack.Screen name="IncidentDetails" component={IncidentDetailsScreen} />
        <Stack.Screen name="DeviceWelcome" component={DeviceWelcomeScreen} />
        <Stack.Screen name="DevicePairingFlow" component={DevicePairingFlowScreen} />
        <Stack.Screen name="RequestBackup" component={RequestBackupScreen} options={{ headerShown: false }} />
        <Stack.Screen name="EmergencyBackup" component={EmergencyBackupScreen} options={{ headerShown: false }} />
      </Stack.Navigator>
    </NavigationContainer>
  );
}

function AppWithNotificationHandler({ navigationRef, emergencyModalVisible, setEmergencyModalVisible, emergencyData, setEmergencyData, modalLoading, setModalLoading, handleEmergencyAccept, handleEmergencyDecline, shouldNavigateToEmergency, setShouldNavigateToEmergency, emergencyRequestId, setEmergencyRequestId, processNotificationResponse, pendingNotificationTrigger }) {
  const { isRecording } = useRecording();
  const { setEmergency } = useNotification();

  // Process pending notification responses when they become available
  useEffect(() => {
    const processPending = async () => {
      if (window.__pendingNotificationResponse) {
        const data = window.__pendingNotificationResponse;
        window.__pendingNotificationResponse = null;

        console.log('[AppWithNotificationHandler] Processing pending notification response:', data);

        // If recording is active, navigate to RecordingScreen
        if (isRecording) {
          console.log('[AppWithNotificationHandler] Recording is active, will navigate to RecordingScreen');
          navigationRef.current?.navigate('Recording');
          
          // Also set the pending emergency in context so RecordingScreen can display it
          if (data?.request_id) {
            setEmergency({
              request_id: data.request_id,
              triggered_by_user_id: data?.triggered_by_user_id,
            });
          }
        }

        // Process the notification data
        await processNotificationResponse(data);
      }
    };

    processPending();
  }, [isRecording, processNotificationResponse, setEmergency, pendingNotificationTrigger]);

  return (
    <>
      <AppNavigator navigationRef={navigationRef} />
      <EmergencyBackupModal
        visible={emergencyModalVisible}
        data={emergencyData}
        loading={modalLoading}
        onAccept={handleEmergencyAccept}
        onDecline={handleEmergencyDecline}
        navigationRef={navigationRef}
        shouldNavigate={shouldNavigateToEmergency}
        setShouldNavigate={setShouldNavigateToEmergency}
        requestId={emergencyRequestId}
        setRequestId={setEmergencyRequestId}
      />
    </>
  );
}

export default function App() {
  const [isReady, setIsReady] = useState(false);
  const isReadyRef = useRef(false); // Use ref for notification handler to access current state
  const navigationRef = useRef();
  const [emergencyModalVisible, setEmergencyModalVisible] = useState(false);
  const [emergencyData, setEmergencyData] = useState(null);
  const [modalLoading, setModalLoading] = useState(false);
  const [shouldNavigateToEmergency, setShouldNavigateToEmergency] = useState(false);
  const [emergencyRequestId, setEmergencyRequestId] = useState(null);
  const [pendingNotificationTrigger, setPendingNotificationTrigger] = useState(0); // Trigger to process pending notifications

  // Update ref whenever isReady changes
  useEffect(() => {
    isReadyRef.current = isReady;
  }, [isReady]);

  // Helper function to process notification responses
  const processNotificationResponse = async (data) => {
    if (!data?.type === 'emergency_backup' || !data?.request_id) {
      console.log('[App] Notification is not emergency_backup or missing request_id');
      return;
    }

    console.log('[App] 📲 Processing emergency backup notification for request_id:', data.request_id);

    try {
      // Fetch emergency backup details from Supabase
      console.log('[App] Fetching emergency backup details...');
      const { data: backupData, error } = await supabase
        .from('emergency_backups')
        .select('*')
        .eq('request_id', data.request_id)
        .single();

      if (error) {
        console.error('[App] ❌ Error fetching emergency backup details:', error);
        if (isReadyRef.current) {
          setTimeout(() => {
            Alert.alert('Error', 'Failed to load emergency details');
          }, 100);
        }
        return;
      }

      if (backupData) {
        console.log('[App] ✅ Emergency backup details fetched:', {
          request_id: backupData.request_id,
          enforcer: backupData.enforcer,
          location: backupData.location
        });

        // Set emergency data and show modal IMMEDIATELY
        console.log('[App] Setting emergency data for request_id:', data.request_id);
        setEmergencyData({
          ...backupData,
          request_id: data.request_id,
          triggered_by_user_id: data?.triggered_by_user_id,
        });

        // Show modal instantly
        console.log('[App] Showing emergency modal...');
        setEmergencyModalVisible(true);

        // Set nav flags if app is ready
        if (isReadyRef.current) {
          setShouldNavigateToEmergency(true);
          setEmergencyRequestId(data.request_id);
        }

        console.log('[App] ✅ Emergency modal visible');
      } else {
        console.warn('[App] No backup data found for request_id:', data.request_id);
        if (isReadyRef.current) {
          setTimeout(() => {
            Alert.alert('Error', 'Emergency backup not found');
          }, 100);
        }
      }
    } catch (fetchErr) {
      console.error('[App] Failed to fetch backup details:', fetchErr);
      if (isReadyRef.current) {
        setTimeout(() => {
          Alert.alert('Error', 'Failed to load emergency details: ' + fetchErr.message);
        }, 100);
      }
    }
  };

  // Setup Firebase and notification listeners globally - runs once at app startup
  useEffect(() => {
    console.log('[App] Setting up global Firebase and notification listeners...');

    // Define notification category with actions (for background)
    Notifications.setNotificationCategoryAsync('emergency_backup', [
      {
        identifier: 'accept',
        buttonTitle: 'ACCEPT',
        options: { isDestructive: false },
      },
      {
        identifier: 'decline',
        buttonTitle: 'DECLINE',
        options: { isDestructive: true },
      },
    ]);

    // Handle Firebase message when app is in foreground
    let unsubscribeForeground = null;
    try {
      unsubscribeForeground = messaging().onMessage(async (remoteMessage) => {
        console.log('[App] Firebase message received (app is active):', remoteMessage.data);
        const data = remoteMessage.data;
        
        if (data?.type === 'emergency_backup' && data?.request_id) {
          console.log('[App] Emergency backup detected, fetching full details...');
          
          try {
            // Fetch full emergency backup details from Supabase
            const { data: backupData, error } = await supabase
              .from('emergency_backups')
              .select('*')
              .eq('request_id', data.request_id)
              .single();
            
            if (error) {
              console.error('[App] Error fetching emergency backup details:', error);
              return;
            }
            
            if (backupData) {
              console.log('[App] ✅ Emergency backup details fetched:', backupData);
              setEmergencyData({
                ...backupData,
                request_id: data.request_id,
                triggered_by_user_id: data?.triggered_by_user_id,
              });
              setEmergencyModalVisible(true);
              
              // Play sound for alert
              await Notifications.presentNotificationAsync({
                title: '🚨 Emergency Backup Alert',
                body: `Officer ${backupData.enforcer} needs backup!`,
                sound: 'default',
                ios: {
                  sound: true,
                },
                android: {
                  sound: 'default',
                  channelId: 'emergency_alerts',
                  priority: 'max',
                  vibrate: [0, 500, 250, 500],
                },
              });
            }
          } catch (err) {
            console.error('[App] Failed to process foreground notification:', err);
          }
        }
      });
    } catch (firebaseError) {
      console.warn('[App] Firebase messaging setup failed:', firebaseError.message);
    }

    // Handle notification response for background notifications (when app is killed/suspended)
    const responseSubscription = Notifications.addNotificationResponseReceivedListener(async (response) => {
      try {
        const { notification } = response;
        const data = notification.request.content.data;
        console.log('[App] 🔔 Background notification tapped:', data);
        
        // Store notification response data to be processed when app is fully ready
        // This will be handled by AppWithNotificationHandler component which has access to contexts
        window.__pendingNotificationResponse = data;
        
        console.log('[App] Notification response stored for later processing');
        
        // Trigger the processing by incrementing the trigger counter
        setPendingNotificationTrigger(prev => prev + 1);
      } catch (err) {
        console.error('[App] Failed to handle background notification:', err);
      }
    });

    // Cleanup subscriptions
    return () => {
      console.log('[App] Cleaning up notification listeners');
      responseSubscription.remove();
      if (unsubscribeForeground) unsubscribeForeground();
    };
  }, []);

  useEffect(() => {
    const prepareApp = async () => {
      try {
        // Get initial URL (from deep link) - kept for future use
        const initialURL = await Linking.getInitialURL();
        if (initialURL != null) {
          console.log('Initial URL:', initialURL);
          // Handle any future deep linking logic here
        }

        // Check for notification response when app starts (cold-start scenario)
        // This handles the case where app was completely killed and notification was tapped
        try {
          const lastNotificationResponse = await Notifications.getLastNotificationResponseAsync();
          if (lastNotificationResponse) {
            console.log('[App] 📬 Cold-start: Found last notification response:', lastNotificationResponse.notification.request.content.data);
            const data = lastNotificationResponse.notification.request.content.data;
            
            // Process the notification using our helper function
            if (data?.type === 'emergency_backup' && data?.request_id) {
              console.log('[App] 🚀 Processing cold-start emergency_backup notification...');
              // Defer processing to next tick so state is ready
              setTimeout(async () => {
                await processNotificationResponse(data);
              }, 100);
            }
          } else {
            console.log('[App] No last notification response on cold-start');
          }
        } catch (notifErr) {
          console.error('[App] Error checking last notification response:', notifErr);
        }
      } catch (e) {
        console.error('Failed to get initial URL:', e);
      } finally {
        // Mark app as ready immediately - notification handler can proceed
        console.log('[App] App initialization complete, setting isReady=true');
        setIsReady(true);
      }
    };

    // Start preparation immediately
    prepareApp();
  }, []);


  const handleEmergencyAccept = async (requestId) => {
    console.log('[App] ========== ACCEPT FLOW STARTED ==========');
    console.log('[App] handleEmergencyAccept called with requestId:', requestId);
    console.log('[App] isReady state:', isReady);
    console.log('[App] navigationRef available:', !!navigationRef.current);
    
    if (!requestId) {
      console.error('[App] ERROR: requestId is missing or falsy!');
      Alert.alert('Error', 'Request ID is missing');
      return;
    }
    
    try {
      setModalLoading(true);
      console.log('[App] 1️⃣  Incrementing responders for request_id:', requestId);
      
      // Fetch current responder count
      const { data: current, error: fetchError } = await supabase
        .from('emergency_backups')
        .select('responders')
        .eq('request_id', requestId)
        .single();
      
      if (fetchError) {
        console.error('[App] ERROR: Fetch error:', fetchError);
        throw new Error(`Failed to fetch responders: ${fetchError.message}`);
      }
      
      if (!current) {
        console.error('[App] ERROR: No data found for request_id:', requestId);
        throw new Error('Emergency backup record not found');
      }
      
      // Update responder count
      const newResponderCount = (current.responders || 0) + 1;
      console.log('[App] Responders:', current.responders, '→', newResponderCount);
      
      const { error: updateError } = await supabase
        .from('emergency_backups')
        .update({ responders: newResponderCount })
        .eq('request_id', requestId);
      
      if (updateError) {
        console.error('[App] ERROR: Update failed:', updateError);
        throw new Error(`Failed to update responders: ${updateError.message}`);
      }
      
      console.log('[App] ✅ 2️⃣  Responders updated to:', newResponderCount);
      
      // Close modal FIRST before navigating
      console.log('[App] 3️⃣  Closing modal...');
      setEmergencyModalVisible(false);
      setEmergencyData(null);
      
      // Wait for modal to close and state to settle
      console.log('[App] Waiting for modal to close...');
      await new Promise(resolve => setTimeout(resolve, 300));
      
      console.log('[App] 4️⃣  Checking navigation readiness...');
      console.log('[App] - isReady:', isReady);
      console.log('[App] - navigationRef.current exists:', !!navigationRef.current);
      
      if (!navigationRef.current) {
        console.error('[App] ❌ CRITICAL: Navigation ref is null/undefined!');
        setModalLoading(false);
        Alert.alert('Navigation Error', 'Unable to navigate - navigation not initialized');
        return;
      }
      
      // Check if we can get current route
      try {
        const currentRoute = navigationRef.current.getCurrentRoute?.();
        console.log('[App] Current route:', currentRoute?.name || 'unknown');
      } catch (routeErr) {
        console.warn('[App] Could not get current route:', routeErr.message);
      }
      
      console.log('[App] 5️⃣  Attempting navigation to EmergencyBackup...');
      console.log('[App] Parameters: { request_id:', requestId, '}');
      
      // Navigate using the correct method - let the screen fetch its own data
      navigationRef.current.navigate('EmergencyBackup', { 
        request_id: requestId 
      });
      
      console.log('[App] ✅ 6️⃣  Navigation command sent');
      console.log('[App] ========== ACCEPT FLOW COMPLETED ==========');
      
    } catch (err) {
      console.error('[App] ❌ ACCEPT FLOW FAILED');
      console.error('[App] Error type:', err?.constructor?.name);
      console.error('[App] Error message:', err?.message);
      console.error('[App] Full error:', err);
      
      // Make sure modal is closed on error
      setEmergencyModalVisible(false);
      setEmergencyData(null);
      
      // Show error to user
      Alert.alert('Error', err?.message || 'Failed to accept emergency alert');
    } finally {
      setModalLoading(false);
    }
  };

  const handleEmergencyDecline = () => {
    console.log('[App] ❌ DECLINE - Closing emergency modal');
    setEmergencyModalVisible(false);
    setEmergencyData(null);
  };

  if (!isReady) {
    return (
      <View style={{ flex: 1, justifyContent: 'center', alignItems: 'center', backgroundColor: '#0B1A33' }}>
        <ActivityIndicator size="large" color="#2E78E6" />
        <Text style={{ marginTop: 16, color: '#fff', fontSize: 14 }}>
          Loading...
        </Text>
      </View>
    );
  }

  return (
    <>
      <AuthProvider>
        <RecordingProvider>
          <NotificationProvider>
            <AppWithNotificationHandler
              navigationRef={navigationRef}
              emergencyModalVisible={emergencyModalVisible}
              setEmergencyModalVisible={setEmergencyModalVisible}
              emergencyData={emergencyData}
              setEmergencyData={setEmergencyData}
              modalLoading={modalLoading}
              setModalLoading={setModalLoading}
              handleEmergencyAccept={handleEmergencyAccept}
              handleEmergencyDecline={handleEmergencyDecline}
              shouldNavigateToEmergency={shouldNavigateToEmergency}
              setShouldNavigateToEmergency={setShouldNavigateToEmergency}
              emergencyRequestId={emergencyRequestId}
              setEmergencyRequestId={setEmergencyRequestId}
              processNotificationResponse={processNotificationResponse}
              pendingNotificationTrigger={pendingNotificationTrigger}
            />
          </NotificationProvider>
        </RecordingProvider>
      </AuthProvider>
    </>
  );
}

// Separate modal component that can access AuthContext
function EmergencyBackupModal({
  visible,
  data,
  loading,
  onAccept,
  onDecline,
  navigationRef,
  shouldNavigate,
  setShouldNavigate,
  requestId,
  setRequestId,
}) {
  const { user } = useAuth();

  // Check if current user triggered this alert
  useEffect(() => {
    if (visible && data && user?.id) {
      console.log('[Modal] ============================================');
      console.log('[Modal] Checking if current user triggered alert...');
      console.log('[Modal] Current user ID:', user.id);
      console.log('[Modal] Modal data:', {
        request_id: data.request_id,
        enforcer: data.enforcer,
        triggered_by_user_id: data.triggered_by_user_id
      });
      console.log('[Modal] ============================================');
      
      if (user.id === data.triggered_by_user_id) {
        console.log('[Modal] ⏭️  Current user triggered this - closing modal');
        onDecline();
      } else {
        console.log('[Modal] ✅ Another user triggered this - showing modal to current user');
      }
    } else if (visible && data && !user?.id) {
      console.log('[Modal] ⏳ Waiting for user auth to complete...');
      // User is still loading, don't close the modal
    }
  }, [visible, data, user?.id]);

  return (
    <Modal
      visible={visible}
      transparent={true}
      animationType="fade"
      onRequestClose={onDecline}
    >
      <View style={styles.modalBackdrop}>
        {!data ? (
          // Show loading state while waiting for data
          <View style={styles.modalCard}>
            <ActivityIndicator size="large" color="#2E78E6" style={{ marginVertical: 30 }} />
            <Text style={{ color: '#fff', textAlign: 'center', marginTop: 16 }}>
              Loading emergency details...
            </Text>
          </View>
        ) : (
          <View style={styles.modalCard}>
            {/* Header */}
            <View style={styles.modalHeader}>
              <View style={styles.alertIconContainer}>
                <Ionicons name="alert-circle" size={20} color="#FF1E1E" />
              </View>
              <View style={{ flex: 1 }}>
                <Text style={styles.modalTitle}>🚨 Emergency Backup Alert</Text>
                <Text style={styles.modalSubtitle}>Officer needs assistance</Text>
              </View>
            </View>

            {/* Divider */}
            <View style={styles.divider} />

            {/* Content */}
            <View style={styles.modalContent}>
              {/* Enforcer */}
              <View style={styles.infoRow}>
                <Text style={styles.infoLabel}>Enforcer:</Text>
                <Text style={styles.infoValue}>{data.enforcer || 'N/A'}</Text>
              </View>

              {/* Location */}
              <View style={styles.infoRow}>
                <Text style={styles.infoLabel}>Location:</Text>
                <Text style={styles.infoValue}>{data.location || 'N/A'}</Text>
              </View>

              {/* Date & Time */}
              <View style={styles.infoRow}>
                <Text style={styles.infoLabel}>Date & Time:</Text>
                <Text style={styles.infoValue}>{data.time || 'N/A'}</Text>
              </View>

              {/* Responders */}
              <View style={styles.infoRow}>
                <Text style={styles.infoLabel}>No. of Responders:</Text>
                <Text style={styles.infoValue}>{data.responders || 0}</Text>
              </View>
            </View>

            {/* Divider */}
            <View style={styles.divider} />

            {/* Buttons */}
            <View style={styles.buttonRow}>
              <TouchableOpacity
                style={[styles.button, styles.declineButton]}
                onPress={onDecline}
                disabled={loading}
                activeOpacity={0.7}
              >
                <Ionicons name="close" size={16} color="white" style={{ marginRight: 6 }} />
                <Text style={styles.declineButtonText}>DECLINE</Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={[styles.button, styles.acceptButton]}
                onPress={() => {
                  console.log('[Modal] ACCEPT button pressed');
                  console.log('[Modal] data.request_id:', data?.request_id);
                  
                  if (!data?.request_id) {
                    console.error('[Modal] ❌ ERROR: request_id is missing!');
                    Alert.alert('Error', 'Emergency backup ID is missing');
                    return;
                  }
                  
                  console.log('[Modal] Calling onAccept with request_id:', data.request_id);
                  onAccept(data.request_id);
                }}
                disabled={loading}
                activeOpacity={0.7}
              >
                {loading ? (
                  <ActivityIndicator size="small" color="#0B1A33" style={{ marginRight: 6 }} />
                ) : (
                  <Ionicons name="checkmark" size={16} color="#0B1A33" style={{ marginRight: 6 }} />
                )}
                <Text style={styles.acceptButtonText}>
                  {loading ? 'ACCEPTING...' : 'ACCEPT'}
                </Text>
              </TouchableOpacity>
            </View>
          </View>
        )}
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  modalBackdrop: {
    flex: 1,
    backgroundColor: 'rgba(0, 0, 0, 0.7)',
    justifyContent: 'center',
    alignItems: 'center',
    paddingHorizontal: 18,
  },
  modalCard: {
    width: '100%',
    maxWidth: 360,
    backgroundColor: '#0F192D',
    borderRadius: 16,
    borderWidth: 2,
    borderColor: 'rgba(255, 30, 30, 0.6)',
    padding: 16,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.3,
    shadowRadius: 12,
    elevation: 8,
  },
  modalHeader: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    marginBottom: 12,
  },
  alertIconContainer: {
    width: 36,
    height: 36,
    borderRadius: 18,
    backgroundColor: 'rgba(255, 30, 30, 0.15)',
    justifyContent: 'center',
    alignItems: 'center',
    marginRight: 12,
  },
  modalTitle: {
    fontSize: 14,
    fontWeight: '800',
    color: 'rgba(255, 255, 255, 0.95)',
    marginBottom: 4,
  },
  modalSubtitle: {
    fontSize: 11,
    color: 'rgba(255, 255, 255, 0.65)',
    fontStyle: 'italic',
  },
  divider: {
    height: 1,
    backgroundColor: 'rgba(255, 255, 255, 0.1)',
    marginVertical: 12,
  },
  modalContent: {
    marginBottom: 4,
  },
  infoRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 10,
    paddingHorizontal: 4,
  },
  infoLabel: {
    fontSize: 11,
    fontWeight: '600',
    color: 'rgba(255, 255, 255, 0.65)',
  },
  infoValue: {
    fontSize: 12,
    fontWeight: '700',
    color: 'rgba(255, 255, 255, 0.92)',
    textAlign: 'right',
    flex: 1,
    marginLeft: 12,
  },
  buttonRow: {
    flexDirection: 'row',
    gap: 12,
    marginTop: 4,
  },
  button: {
    flex: 1,
    height: 44,
    borderRadius: 10,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 1,
  },
  declineButton: {
    backgroundColor: 'rgba(255, 30, 30, 0.15)',
    borderColor: 'rgba(255, 30, 30, 0.4)',
  },
  declineButtonText: {
    fontSize: 12,
    fontWeight: '700',
    color: 'rgba(255, 255, 255, 0.85)',
    letterSpacing: 0.3,
  },
  acceptButton: {
    backgroundColor: '#3DDC84',
    borderColor: 'rgba(61, 220, 132, 0.5)',
  },
  acceptButtonText: {
    fontSize: 12,
    fontWeight: '800',
    color: '#0B1A33',
    letterSpacing: 0.4,
  },
});
