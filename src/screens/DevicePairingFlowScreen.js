import React, { useEffect, useState } from "react";
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
import supabase from "../lib/supabase"; // Authenticated client

export default function DevicePairingFlowScreen({ navigation }) {
  const { displayName, badge, logout, user } = useAuth();

  // Simplified state: We only need to know if we are scanning or not
  const [isScanning, setIsScanning] = useState(false);
  const [statusMessage, setStatusMessage] = useState("");
  const [statusError, setStatusError] = useState(null);

  // ------------------------------------------------------------------
  //  POLLING LOGIC (Runs every 5s when isScanning is true)
  // ------------------------------------------------------------------
  useEffect(() => {
    let intervalId;

    if (isScanning && user?.id) {
      const checkForDevice = async () => {
        try {
          console.log("[DevicePairing] Polling Supabase...");

          // We look for records updated/created in the last 1 HOUR to capture the recent pairing
          const timeWindow = new Date(Date.now() - 60 * 60 * 1000).toISOString();

          const { data, error } = await supabase
            .from('device_credentials')
            .select('device_id, device_name')
            .eq('user_id', user.id)
            .or(`updated_at.gte.${timeWindow},created_at.gte.${timeWindow},provisioned_at.gte.${timeWindow}`)
            .limit(1);

          if (error) {
            console.warn("[DevicePairing] Poll error:", error.message);
          }

          if (data && data.length > 0) {
            console.log("[DevicePairing] Device found!", data[0]);

            // 1. Stop Scanning
            clearInterval(intervalId);
            setIsScanning(false);

            // 2. Save Local State
            await setPaired(true);
            setStatusMessage("✓ Device Connected Successfully!");

            // 3. Navigate
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
            // Still waiting...
            console.log("[DevicePairing] No record found yet.");
          }

        } catch (e) {
          console.log("[DevicePairing] Network request failed (likely no internet yet):", e.message);
          // We don't stop the loop; we just wait for the phone to reconnect to cellular/WiFi
        }
      };

      // Poll immediately then every 5 seconds
      checkForDevice();
      intervalId = setInterval(checkForDevice, 5000);
    }

    return () => {
      if (intervalId) clearInterval(intervalId);
    };
  }, [isScanning, user, navigation]);


  // ------------------------------------------------------------------
  //  ACTION HANDLERS
  // ------------------------------------------------------------------

  const handleStartProvisioning = async () => {
    try {
      setStatusError(null);

      if (!user || !user.id) {
        Alert.alert("Error", "You must be logged in to provision a device.");
        return;
      }

      const userId = user.id;
      // Pass the user_id to the Pi so it can forward it to Supabase
      const url = `http://192.168.50.1:8000/provisioning?user_id=${encodeURIComponent(userId)}`;

      const supported = await Linking.canOpenURL(url);

      if (supported) {
        // 1. Open the browser
        await Linking.openURL(url);

        // 2. Immediately switch UI to "Scanning" mode
        setIsScanning(true);
        setStatusMessage("Waiting for device to connect to cloud...");

      } else {
        Alert.alert(
          "Connection Error",
          "Cannot reach the device. Make sure you are connected to the 'EVVOS_0001' WiFi network."
        );
      }
    } catch (error) {
      console.error("[DevicePairing] Error starting provisioning:", error);
      setStatusError("Failed to open provisioning form.");
    }
  };

  const handleStopScanning = () => {
    setIsScanning(false);
    setStatusMessage("");
  };

  const handleGoBack = () => {
    if (isScanning) {
      Alert.alert("Cancel Setup?", "We are still waiting for your device to connect.", [
        { text: "Keep Waiting", style: "cancel" },
        {
          text: "Exit",
          style: "destructive",
          onPress: () => {
            setIsScanning(false);
            navigation.goBack();
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

  // ------------------------------------------------------------------
  //  RENDER
  // ------------------------------------------------------------------

  const renderContent = () => {
    return (
      <>
        <Text style={styles.stepText}>Device Provisioning</Text>
        <Text style={styles.bodyText}>
          Follow the steps below to connect your E.V.V.O.S device to the cloud.
        </Text>

        <View style={styles.imageBox}>
          {isScanning ? (
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

        {/* Status Message Display */}
        {statusMessage !== "" && (
          <View style={isScanning ? styles.loadingBox : styles.statusBox}>
            <Text style={isScanning ? styles.loadingText : styles.statusText}>
              {statusMessage}
            </Text>
          </View>
        )}

        {/* Instructions only visible when NOT scanning */}
        {!isScanning && (
          <View style={styles.infoBox}>
            <Ionicons name="information-circle-outline" size={16} color="#6DA8FF" />
            <Text style={styles.infoText}>
              1. Connect to WiFi: "EVVOS_0001"{'\n'}
              2. Turn off Mobile Data{'\n'}
              3. Press "Start Provisioning"
            </Text>
          </View>
        )}

        {!isScanning ? (
          <TouchableOpacity
            style={styles.primaryBtn}
            activeOpacity={0.9}
            onPress={handleStartProvisioning}
          >
            <View style={styles.btnIconCircle}>
              <Ionicons name="play" size={25} color="white" />
            </View>
            <Text style={styles.primaryText}>Start Provisioning</Text>
          </TouchableOpacity>
        ) : (
          <View>
            {/* While scanning, we show instructions on what to do next */}
            <View style={styles.infoBox}>
              <Ionicons name="phone-portrait-outline" size={16} color="#6DA8FF" />
              <Text style={styles.infoText}>
                After entering WiFi details in the browser, your device will restart.
                {"\n\n"}
                Please ensure your phone reconnects to the Internet (Mobile Data/Home WiFi) so we can detect the device.
              </Text>
            </View>

            <TouchableOpacity
              style={[styles.secondaryBtn]}
              activeOpacity={0.8}
              onPress={handleStopScanning}
            >
              <Text style={styles.secondaryText}>Cancel / Retry</Text>
            </TouchableOpacity>
          </View>
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
  secondaryBtn: {
    height: 44,
    width: "100%",
    borderRadius: 10,
    backgroundColor: "rgba(255, 255, 255, 0.1)",
    borderWidth: 1,
    borderColor: "rgba(255, 255, 255, 0.2)",
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    marginTop: 10,
  },
  primaryText: {
    color: "white",
    fontSize: 15,
    fontWeight: "800",
  },
  secondaryText: {
    color: "rgba(255,255,255,0.8)",
    fontSize: 14,
    fontWeight: "600",
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
  loadingBox: {
    backgroundColor: "rgba(21,200,90,0.1)",
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "rgba(21,200,90,0.3)",
    padding: 12,
    marginBottom: 14,
    alignItems: "center",
  },
  loadingText: {
    color: "#15C85A",
    fontSize: 13,
    fontWeight: "600",
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