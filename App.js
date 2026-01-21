import React, { useRef, useEffect, useState } from "react";
import { NavigationContainer } from "@react-navigation/native";
import { createNativeStackNavigator } from "@react-navigation/native-stack";
import { StatusBar } from "expo-status-bar";
import * as Notifications from 'expo-notifications';
import { Linking, ActivityIndicator, View, Text, Alert } from 'react-native';
import supabase from './src/lib/supabase';

import { AuthProvider, useAuth } from "./src/context/AuthContext";

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

// Loading Screen Component
function LoadingScreen({ navigation }) {
  const { loading, isAuthenticated } = useAuth();

  useEffect(() => {
    if (!loading) {
      navigation.replace(isAuthenticated ? "Home" : "Login");
    }
  }, [loading, isAuthenticated, navigation]);

  return (
    <View style={{ flex: 1, justifyContent: 'center', alignItems: 'center', backgroundColor: '#0B1A33' }}>
      <ActivityIndicator size="large" color="#2E78E6" />
      <Text style={{ marginTop: 16, color: '#fff', fontSize: 14 }}>
        Loading...
      </Text>
    </View>
  );
}

// Deep linking configuration - kept for future use but not currently used for password reset
const linking = {
  prefixes: ['evvos://'],
  config: {
    screens: {
      // Add other deep link screens here if needed
    },
  },
};

function AppNavigator() {
  const navigationRef = useRef();
  const { recoveryMode, isAuthenticated, loading } = useAuth();

  // Navigate to password reset screen when recovery mode is detected
  useEffect(() => {
    if (recoveryMode) {
      console.log('Recovery mode detected, navigating to CreateNewPassword');
      navigationRef.current?.navigate('CreateNewPassword');
    }
  }, [recoveryMode]);

  useEffect(() => {
    // Define notification category with actions
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

    // Handle notification when app is foreground
    const subscription = Notifications.addNotificationReceivedListener(notification => {
      const data = notification.request.content.data;
      if (data?.type === 'emergency_backup' && data?.request_id) {
        // Present local notification with actions
        Notifications.presentNotificationAsync({
          title: notification.request.content.title,
          body: notification.request.content.body,
          data: data,
          categoryIdentifier: 'emergency_backup',
        });
      }
    });

    // Handle notification response (when user taps on notification or actions)
    const responseSubscription = Notifications.addNotificationResponseReceivedListener(async response => {
      const { actionIdentifier, notification } = response;
      const data = notification.request.content.data;
      if (data?.type === 'emergency_backup' && data?.request_id) {
        if (actionIdentifier === 'accept') {
          // Update responders count
          try {
            const { data: current } = await supabase
              .from('emergency_backups')
              .select('responders')
              .eq('request_id', data.request_id)
              .single();
            if (current) {
              await supabase
                .from('emergency_backups')
                .update({ responders: current.responders + 1 })
                .eq('request_id', data.request_id);
            }
          } catch (err) {
            console.warn('Failed to update responders:', err);
          }
          // Navigate to EmergencyBackupScreen
          navigationRef.current?.navigate('EmergencyBackup', { request_id: data.request_id });
        } else if (actionIdentifier === 'decline') {
          // Do nothing
        } else {
          // Default tap, navigate
          navigationRef.current?.navigate('EmergencyBackup', { request_id: data.request_id });
        }
      }
    });

    return () => {
      subscription.remove();
      responseSubscription.remove();
    };
  }, []);

  return (
    <NavigationContainer ref={navigationRef} linking={linking}>
      <StatusBar style="light" />
      <Stack.Navigator initialRouteName="Loading" screenOptions={{ headerShown: false }}>
        <Stack.Screen name="Loading" component={LoadingScreen} />
        <Stack.Screen name="Login" component={LoginScreen} />
        <Stack.Screen name="ForgotPassword" component={ForgotPasswordScreen} />
        <Stack.Screen name="CreateNewPassword" component={CreateNewPasswordScreen} />
        <Stack.Screen name="Home" component={HomeScreen} />
        <Stack.Screen name="Recording" component={RecordingScreen} />
        <Stack.Screen name="IncidentSummary" component={IncidentSummaryScreen} />
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

export default function App() {
  const [isReady, setIsReady] = useState(false);

  useEffect(() => {
    const prepareApp = async () => {
      try {
        // Get initial URL (from deep link) - kept for future use
        const initialURL = await Linking.getInitialURL();
        if (initialURL != null) {
          console.log('Initial URL:', initialURL);
          // Handle any future deep linking logic here
        }
      } catch (e) {
        console.error('Failed to get initial URL:', e);
      } finally {
        setIsReady(true);
      }
    };

    prepareApp();
  }, []);

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
    <AuthProvider>
      <AppNavigator />
    </AuthProvider>
  );
}
