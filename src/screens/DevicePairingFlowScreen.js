import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  ActivityIndicator,
  ScrollView,
  Alert,
  Linking,
} from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";
import { setPaired } from "../utils/deviceStore";
import { useAuth } from "../context/AuthContext";
import { supabaseUrl, supabaseAnonKey } from "../lib/supabase";
import { createClient } from "@supabase/supabase-js";

export default function DevicePairingFlowScreen({ navigation }) {
  const { displayName, badge, logout, user } = useAuth();
  const [step, setStep] = useState(0);
  const [formOpened, setFormOpened] = useState(false);
  const [credentialsReceived, setCredentialsReceived] = useState(false);
  const [checking, setChecking] = useState(false);
  const [statusError, setStatusError] = useState(null);
  const [statusMessage, setStatusMessage] = useState("");
  const [isProvisioning, setIsProvisioning] = useState(false);
  const checkingTimerRef = useRef(null);

  // Initialize Supabase Client
  const supabase = useMemo(() => createClient(supabaseUrl, supabaseAnonKey), []);

  // Cleanup timer on unmount
  useEffect(() => {
    return () => {
      if (checkingTimerRef.current) clearTimeout(checkingTimerRef.current);
    };
  }, []);

  /**
   * Monitor for credentials received from Pi (Local Network Check)
   */
  useEffect(() => {
    if (formOpened && !credentialsReceived && !checking) {
      const checkCredentials = async () => {
        try {
          // Poll the Pi directly to see if it received the form data
          const response = await fetch("http://192.168.50.1:8000/check-credentials", {
            method: "GET",
            timeout: 3000,
          }).catch(() => null);

          if (response && response.ok) {
            const data = await response.json();
            if (data.received) {
              setCredentialsReceived(true);
              setStatusMessage("Credentials received! Device is connecting to cloud...");
            }
          }
        } catch (error) {
          // Silent fail during polling
        }
      };

      const interval = setInterval(checkCredentials, 2000);
      return () => clearInterval(interval);
    }
  }, [formOpened, credentialsReceived, checking]);

  /**
   * Handle starting provisioning
   */
  const handleStartProvisioning = async () => {
    try {
      setStatusError(null);
      setStatusMessage("");

      if (!user || !user.id) {
        Alert.alert("Error", "You must be logged in to provision a device.");
        return;
      }

      setIsProvisioning(true);
      const userId = user.id;
      // Pass the user_id to the Pi so it can forward it to Supabase
      const url = `http://192.168.50.1:8000/provisioning?user_id=${encodeURIComponent(userId)}`;

      const supported = await Linking.canOpenURL(url);
      if (supported) {
        setFormOpened(true);
        setStatusMessage("Opening provisioning form...");
        await Linking.openURL(url);
        // Add a slight delay to allow browser to open before updating message
        setTimeout(() => {
          setStatusMessage("Please enter your Hotspot SSID and Password in the browser.");
        }, 1000);
      } else {
        Alert.alert("Error", "Cannot open URL. Make sure you're connected to EVVOS_0001 WiFi.");
        setIsProvisioning(false);
      }
    } catch (error) {
      console.error("[DevicePairing] Error starting provisioning:", error);
      setStatusError("Failed to open form. Ensure connection to EVVOS_0001.");
      setIsProvisioning(false);
    }
  };

  /**
   * POLL SUPABASE: Verify the device successfully registered the user_id
   */
  const verifyDeviceRegistration = async () => {
    console.log("[DevicePairing] Polling Supabase for device registration...");

    // Attempt for 90 seconds (30 attempts x 3 seconds)
    // We need a longer timeout because the Pi has to:
    // 1. Stop Hotspot -> 2. Connect to User WiFi -> 3. Wait for DHCP -> 4. Call Edge Function
    const maxAttempts = 30;

    for (let i = 0; i < maxAttempts; i++) {
      try {
        console.log(`[DevicePairing] Verification attempt ${i + 1}/${maxAttempts}`);
        setStatusMessage(`Scanning for device connection... (${Math.round((i / maxAttempts) * 100)}%)`);

        // Check for a record created in the last 10 minutes to ensure it's FRESH
        const tenMinutesAgo = new Date(Date.now() - 10 * 60 * 1000).toISOString();

        const { data, error } = await supabase
          .from('device_credentials') // Ensure this matches your Table Name
          .select('*')
          .eq('user_id', user.id)
          .gte('created_at', tenMinutesAgo)
          .order('created_at', { ascending: false })
          .limit(1);

        if (data && data.length > 0) {
          console.log("[DevicePairing] ✓ Device successfully synced with Supabase!");
          return true;
        }

        if (error) {
          console.warn("[DevicePairing] Poll warning:", error.message);
        }

      } catch (e) {
        console.log("[DevicePairing] Network error during polling (waiting for internet):", e);
      }

      // Wait 3 seconds before next attempt
      await new Promise(resolve => setTimeout(resolve, 3000));
    }

    return false;
  };

  /**
   * Handle completing provisioning
   */
  const handleComplete = async () => {
    // 1. Alert the user to switch networks first
    Alert.alert(
      "Confirm Connection",
      "To finish setup, your phone must have Internet access.\n\n1. Disconnect from 'EVVOS_0001'\n2. Enable Mobile Data or connect to your Home WiFi\n\nPress OK when you have internet.",
      [
        {
          text: "Cancel",
          style: "cancel"
        },
        {
          text: "I have Internet",
          onPress: async () => {
            performVerification();
          }
        }
      ]
    );
  };

  const performVerification = async () => {
    setChecking(true);
    setStatusMessage("Searching for device on the network...");

    try {
      // 2. Poll Supabase
      const isRegistered = await verifyDeviceRegistration();

      if (isRegistered) {
        // 3. Success! Save local state and navigate
        await setPaired(true);
        setStatusMessage("✓ Device Paired Successfully!");

        Alert.alert("Success", "Your E.V.V.O.S device is now online and paired.", [
          {
            text: "Go to Dashboard",
            onPress: () => {
              navigation.reset({
                index: 0,
                routes: [{ name: "Home" }],
              });
            }
          }
        ]);
      } else {
        // 4. Timeout
        throw new Error("Timeout: Device did not report to cloud in time.");
      }

    } catch (error) {
      console.error("[DevicePairing] Verification failed:", error);
      Alert.alert(
        "Pairing Not Found",
        "We couldn't find the device online yet.\n\n1. Ensure you entered the correct WiFi password.\n2. Ensure your phone has internet.\n3. Try pressing 'Complete Setup' again in a moment.",
        [{ text: "OK" }]
      );
      setChecking(false);
      setStatusMessage("Verification failed. Please try again.");
    }
  };

  const handleGoBack = () => {
    if (formOpened) {
      Alert.alert("Exit Setup?", "Your device might still be connecting.", [
        { text: "Stay", style: "cancel" },
        {
          text: "Exit",
          style: "destructive",
          onPress: () => {
            setFormOpened(false);
            setCredentialsReceived(false);
            setStatusMessage("");
            setIsProvisioning(false);
          }
        }
      ]);
    } else {
      navigation.goBack();
    }
  };

  const handleLogout = () => {
    Alert.alert("Logout", "Are you sure you want to logout?", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Logout",
        style: "destructive",
        onPress: async () => {
          await logout();
          navigation.reset({ index: 0, routes: [{ name: "Login" }] });
        },
      },
    ]);
  };

  const renderContent = () => {
    return (
      <>
        <Text style={styles.stepText}>Device Provisioning</Text>
        <Text style={styles.bodyText}>
          Follow the steps below to connect your E.V.V.O.S device to the cloud.
        </Text>

        <View style={styles.imageBox}>
          {checking ? (
            <ActivityIndicator size={64} color="#15C85A" />
          ) : (
            <Ionicons name="wifi" size={64} color="rgba(255,255,255,0.85)" />
          )}
        </View>

        {statusError && (
          <View style={styles.errorBox}>
            <Text style={styles.errorText}>{statusError}</Text>
          </View>
        )}

        {statusMessage !== "" && (
          <View style={credentialsReceived ? styles.successBox : styles.statusBox}>
            <Text style={credentialsReceived ? styles.successText : styles.statusText}>
              {statusMessage}
            </Text>
          </View>
        )}

        {!formOpened && (
          <View style={styles.infoBox}>
            <Ionicons name="information-circle-outline" size={16} color="#6DA8FF" />
            <Text style={styles.infoText}>
              1. Connect to WiFi: "EVVOS_0001"{'\n'}
              2. Turn off Mobile Data{'\n'}
              3. Press "Start Provisioning"
            </Text>
          </View>
        )}

        {!formOpened ? (
          <TouchableOpacity
            style={[styles.primaryBtn, isProvisioning && styles.disabledBtn]}
            activeOpacity={isProvisioning ? 0.5 : 0.9}
            onPress={handleStartProvisioning}
            disabled={isProvisioning}
          >
            <View style={styles.btnIconCircle}>
              <Ionicons name={isProvisioning ? "hourglass" : "play"} size={25} color="white" />
            </View>
            <Text style={styles.primaryText}>
              {isProvisioning ? "Opening..." : "Start Provisioning"}
            </Text>
          </TouchableOpacity>
        ) : (
          <>
            {credentialsReceived ? (
              <>
                <View style={styles.infoBox}>
                  <Ionicons name="cloud-done-outline" size={16} color="#6DA8FF" />
                  <Text style={styles.infoText}>
                    Credentials sent! The device is restarting. Please reconnect your phone to the Internet now.
                  </Text>
                </View>

                <TouchableOpacity
                  style={[styles.primaryBtn, checking && styles.disabledBtn]}
                  activeOpacity={0.9}
                  onPress={handleComplete}
                  disabled={checking}
                >
                  <View style={styles.btnIconCircle}>
                    {checking ? (
                      <ActivityIndicator size="small" color="white" />
                    ) : (
                      <Ionicons name="checkmark-done" size={25} color="white" />
                    )}
                  </View>
                  <Text style={styles.primaryText}>
                    {checking ? "Verifying..." : "Complete Setup"}
                  </Text>
                </TouchableOpacity>
              </>
            ) : (
              <TouchableOpacity
                style={[styles.primaryBtn, styles.disabledBtn]}
                disabled={true}
              >
                <View style={styles.btnIconCircle}>
                  <ActivityIndicator size="small" color="white" />
                </View>
                <Text style={styles.primaryText}>Waiting for Browser Input...</Text>
              </TouchableOpacity>
            )}
          </>
        )}
      </>
    );
  };

  return (
    <LinearGradient
      colors={["#0B1A33", "#3D5F91"]}
      start={{ x: 0.5, y: 0 }}
      end={{ x: 0.5, y: 1 }}
      style={{ flex: 1 }}
    >
      <SafeAreaView style={{ flex: 1 }}>
        <View style={styles.topBar}>
          <View style={{ flexDirection: "row", alignItems: "center" }}>
            <Ionicons name="person-circle" size={26} color="#4DB5FF" />
            <View style={{ marginLeft: 8 }}>
              <Text style={styles.officerName}>Officer {displayName}</Text>
              <Text style={styles.badge}>{badge ? `Badge #${badge}` : ""}</Text>
            </View>
          </View>

          <View style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
            <TouchableOpacity activeOpacity={0.9} onPress={handleLogout}>
              <Ionicons name="log-out-outline" size={18} color="rgba(255,255,255,0.75)" />
            </TouchableOpacity>
            <TouchableOpacity activeOpacity={0.9} onPress={handleGoBack}>
              <Ionicons name="arrow-back" size={18} color="rgba(255,255,255,0.75)" />
            </TouchableOpacity>
          </View>
        </View>

        <ScrollView contentContainerStyle={styles.page} showsVerticalScrollIndicator={false}>
          {renderContent()}

          <Text style={styles.footer}>Public Safety and Traffic Management Department</Text>
        </ScrollView>
      </SafeAreaView>
    </LinearGradient>
  );
}

const styles = StyleSheet.create({
  topBar: {
    paddingHorizontal: 16,
    paddingTop: 4,
    paddingBottom: 10,
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
  },
  officerName: {
    color: "rgba(255,255,255,0.90)",
    fontSize: 12,
    fontWeight: "700",
  },
  badge: {
    color: "rgba(255,255,255,0.55)",
    fontSize: 10,
    marginTop: 2,
  },
  page: {
    flexGrow: 1,
    paddingHorizontal: 18,
    paddingTop: 18,
    paddingBottom: 36,
  },
  stepText: {
    color: "rgba(255,255,255,0.92)",
    fontSize: 13,
    fontWeight: "800",
    marginBottom: 8,
  },
  bodyText: {
    color: "rgba(255,255,255,0.70)",
    fontSize: 12,
    lineHeight: 18,
    marginBottom: 16,
  },
  imageBox: {
    height: 190,
    width: "100%",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.12)",
    backgroundColor: "rgba(0,0,0,0.12)",
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 14,
  },
  primaryBtn: {
    height: 50,
    width: "100%",
    borderRadius: 12,
    backgroundColor: "#15C85A",
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 10,
    marginTop: 18,
  },
  disabledBtn: {
    backgroundColor: "rgba(21,200,90,0.5)",
    opacity: 0.6,
  },
  primaryText: {
    color: "white",
    fontSize: 15,
    fontWeight: "800",
  },
  statusBox: {
    backgroundColor: "rgba(255,255,255,0.08)",
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.12)",
    padding: 12,
    marginBottom: 14,
    alignItems: "center",
  },
  statusText: {
    color: "rgba(255,255,255,0.70)",
    fontSize: 12,
  },
  errorBox: {
    backgroundColor: "rgba(255,30,30,0.15)",
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "rgba(255,30,30,0.3)",
    padding: 12,
    marginBottom: 12,
  },
  errorText: {
    color: "rgba(255,150,150,0.90)",
    fontSize: 11,
    lineHeight: 16,
  },
  infoBox: {
    backgroundColor: "rgba(109,168,255,0.12)",
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "rgba(109,168,255,0.3)",
    padding: 12,
    marginBottom: 12,
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
  },
  infoText: {
    color: "rgba(109,168,255,0.85)",
    fontSize: 11,
    lineHeight: 16,
    flex: 1,
  },
  successBox: {
    backgroundColor: "rgba(21,200,90,0.15)",
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "rgba(21,200,90,0.3)",
    padding: 12,
    marginBottom: 12,
    alignItems: "center",
  },
  successText: {
    color: "rgba(21,200,90,0.85)",
    fontSize: 12,
    fontWeight: "600",
  },
  btnIconCircle: {
    width: 24,
    height: 24,
    borderRadius: 12,
    backgroundColor: "rgba(255,255,255,0.2)",
    alignItems: "center",
    justifyContent: "center",
  },
  footer: {
    marginTop: 22,
    alignSelf: "center",
    color: "rgba(255,255,255,0.25)",
    fontSize: 10,
  },
});