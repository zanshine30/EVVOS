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
  Vibration,
} from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";
import { CameraView, useCameraPermissions } from "expo-camera"; // Updated for generic Expo Camera
import { setPaired } from "../utils/deviceStore";
import { useAuth } from "../context/AuthContext";
import supabase from "../lib/supabase";

export default function DevicePairingFlowScreen({ navigation }) {
  const { displayName, badge, logout, user } = useAuth();

  // Camera & Permissions
  const [permission, requestPermission] = useCameraPermissions();
  const [scanned, setScanned] = useState(false);
  const [showManualButton, setShowManualButton] = useState(false);
  const [scanFailCount, setScanFailCount] = useState(0); // Tracks invalid scans

  // Provisioning State
  const [isScanning, setIsScanning] = useState(false); // "Scanning" here means "Waiting for Cloud connection"
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
          const timeWindow = new Date(Date.now() - 60 * 60 * 1000).toISOString();

          const { data, error } = await supabase
            .from('device_credentials')
            .select('device_id, device_name')
            .eq('user_id', user.id)
            .or(`updated_at.gte.${timeWindow},created_at.gte.${timeWindow},provisioned_at.gte.${timeWindow}`)
            .limit(1);

          if (data && data.length > 0) {
            clearInterval(intervalId);
            setIsScanning(false);
            await setPaired(true);
            setStatusMessage("✓ Device Connected Successfully!");

            Alert.alert("Success", "Your E.V.V.O.S device is now online and paired.", [
              {
                text: "Go to Dashboard",
                onPress: () => {
                  navigation.reset({ index: 0, routes: [{ name: "Home" }] });
                }
              }
            ]);
          }
        } catch (e) {
          console.log("[DevicePairing] Network request failed:", e.message);
        }
      };

      checkForDevice();
      intervalId = setInterval(checkForDevice, 5000);
    }
    return () => { if (intervalId) clearInterval(intervalId); };
  }, [isScanning, user, navigation]);

  // ------------------------------------------------------------------
  //  QR CODE HANDLER
  // ------------------------------------------------------------------
  const handleBarCodeScanned = async ({ type, data }) => {
    if (scanned || isScanning) return; // Prevent double trigger

    // 1. Validation Logic
    // We expect the QR to contain the base URL like "http://192.168.50.1:8000/provisioning"
    // Adjust this check based on your actual QR content requirements.
    const isValidQR = data.includes("192.168.50.1") || data.includes("provisioning");

    if (!isValidQR) {
      setScanned(true);
      Vibration.vibrate(); // Feedback for error

      const newCount = scanFailCount + 1;
      setScanFailCount(newCount);

      if (newCount >= 3) {
        // TRIGGER FALLBACK after 3 failed attempts
        Alert.alert(
          "Scanning Failed",
          "We cannot recognize this device. Switching to manual mode.",
          [{ text: "OK", onPress: () => setShowManualButton(true) }]
        );
      } else {
        Alert.alert("Invalid Device", "This QR code does not match an EVVOS device. Try again.", [
          { text: "OK", onPress: () => setScanned(false) } // Reset scan lock
        ]);
      }
      return;
    }

    // 2. Success Logic
    setScanned(true);
    Vibration.vibrate();

    // Append user_id to the scanned URL
    const finalUrl = `${data}?user_id=${encodeURIComponent(user.id)}`;

    // Proceed to open browser
    openProvisioningUrl(finalUrl);
  };

  // ------------------------------------------------------------------
  //  MANUAL / COMMON ACTIONS
  // ------------------------------------------------------------------

  const openProvisioningUrl = async (url) => {
    try {
      const supported = await Linking.canOpenURL(url);
      if (supported) {
        await Linking.openURL(url);
        setIsScanning(true); // Start polling
        setStatusMessage("Waiting for device to connect to cloud...");
      } else {
        Alert.alert("Error", "Cannot open the link provided by the device.");
        setScanned(false);
      }
    } catch (err) {
      console.error(err);
      setStatusError("Failed to open provisioning link.");
      setScanned(false);
    }
  };

  const handleManualProvisioning = () => {
    // Default fallback URL if QR fails
    const defaultUrl = `http://192.168.50.1:8000/provisioning?user_id=${encodeURIComponent(user.id)}`;
    openProvisioningUrl(defaultUrl);
  };

  const handleStopScanning = () => {
    setIsScanning(false);
    setStatusMessage("");
    setScanned(false); // Re-enable camera
  };

  const handleGoBack = () => {
    if (isScanning) {
      Alert.alert("Cancel Setup?", "We are still waiting for your device to connect.", [
        { text: "Keep Waiting", style: "cancel" },
        { text: "Exit", style: "destructive", onPress: () => navigation.goBack() }
      ]);
    } else {
      navigation.goBack();
    }
  };

  const handleLogout = async () => {
    await logout();
    navigation.reset({ index: 0, routes: [{ name: "Login" }] });
  };

  // ------------------------------------------------------------------
  //  RENDER
  // ------------------------------------------------------------------

  // Helper to render Camera or Icon based on state
  const renderScannerArea = () => {
    // If waiting for cloud, show loading spinner
    if (isScanning) {
      return (
        <View style={styles.imageBox}>
          <ActivityIndicator size={64} color="#15C85A" />
        </View>
      );
    }

    // If Manual Button was triggered (either by 3 fails or user click)
    if (showManualButton) {
      return (
        <View style={styles.imageBox}>
          <Ionicons name="keypad" size={64} color="rgba(255,255,255,0.85)" />
          <Text style={styles.manualModeText}>Manual Mode Active</Text>
        </View>
      );
    }

    // Permission Handling
    if (!permission) return <View style={styles.imageBox} />;
    if (!permission.granted) {
      return (
        <TouchableOpacity style={styles.imageBox} onPress={requestPermission}>
          <Ionicons name="camera-outline" size={48} color="white" />
          <Text style={{ color: "white", marginTop: 10 }}>Tap to Enable Camera</Text>
        </TouchableOpacity>
      );
    }

    // Live Camera View
    return (
      <View style={styles.cameraContainer}>
        <CameraView
          style={StyleSheet.absoluteFillObject}
          facing="back"
          onBarcodeScanned={scanned ? undefined : handleBarCodeScanned}
          barcodeScannerSettings={{
            barcodeTypes: ["qr"],
          }}
        />
        {/* Overlay Frame */}
        <View style={styles.overlayLayer}>
          <View style={styles.scanFrame} />
          <Text style={styles.scanText}>Scan Device QR Code</Text>
        </View>
      </View>
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
          <View style={{ flexDirection: "row", gap: 12 }}>
            <TouchableOpacity onPress={handleLogout}><Ionicons name="log-out-outline" size={18} color="rgba(255,255,255,0.75)" /></TouchableOpacity>
            <TouchableOpacity onPress={handleGoBack}><Ionicons name="arrow-back" size={18} color="rgba(255,255,255,0.75)" /></TouchableOpacity>
          </View>
        </View>

        <ScrollView contentContainerStyle={styles.page} showsVerticalScrollIndicator={false}>
          <Text style={styles.stepText}>Device Provisioning</Text>
          <Text style={styles.bodyText}>
            {showManualButton
              ? "Press the button below to connect manually."
              : "Scan the QR code found on your device screen to begin."}
          </Text>

          {/* DYNAMIC AREA: Camera OR Icon */}
          {renderScannerArea()}

          {statusError && (
            <View style={styles.errorBox}>
              <Text style={styles.errorText}>{statusError}</Text>
            </View>
          )}

          {statusMessage !== "" && (
            <View style={isScanning ? styles.loadingBox : styles.statusBox}>
              <Text style={isScanning ? styles.loadingText : styles.statusText}>{statusMessage}</Text>
            </View>
          )}

          {/* INSTRUCTIONS */}
          {!isScanning && (
            <View style={styles.infoBox}>
              <Ionicons name="information-circle-outline" size={16} color="#6DA8FF" />
              <Text style={styles.infoText}>
                1. Connect to WiFi: "EVVOS_0001"{'\n'}
                2. Turn off Mobile Data{'\n'}
                3. {showManualButton ? "Press Button" : "Scan QR Code"}
              </Text>
            </View>
          )}

          {/* BUTTONS LOGIC */}
          {!isScanning ? (
            <>
              {/* Show Manual Button ONLY if triggered */}
              {showManualButton ? (
                <TouchableOpacity
                  style={styles.primaryBtn}
                  activeOpacity={0.9}
                  onPress={handleManualProvisioning}
                >
                  <View style={styles.btnIconCircle}>
                    <Ionicons name="play" size={25} color="white" />
                  </View>
                  <Text style={styles.primaryText}>Start Provisioning (Manual)</Text>
                </TouchableOpacity>
              ) : (
                /* Or show "Trouble Scanning?" toggle */
                <TouchableOpacity
                  style={styles.textLinkBtn}
                  onPress={() => setShowManualButton(true)}
                >
                  <Text style={styles.textLink}>Trouble Scanning? Use Manual Button</Text>
                </TouchableOpacity>
              )}

              {/* If user is in manual mode, allow them to go back to camera */}
              {showManualButton && (
                <TouchableOpacity
                  style={styles.textLinkBtn}
                  onPress={() => {
                    setShowManualButton(false);
                    setScanFailCount(0);
                    setScanned(false);
                  }}
                >
                  <Text style={styles.textLink}>Switch back to Camera</Text>
                </TouchableOpacity>
              )}
            </>
          ) : (
            <View>
              <View style={styles.infoBox}>
                <Ionicons name="phone-portrait-outline" size={16} color="#6DA8FF" />
                <Text style={styles.infoText}>
                  Your device is restarting...{'\n'}
                  Please reconnect your phone to the Internet now.
                </Text>
              </View>
              <TouchableOpacity style={styles.secondaryBtn} onPress={handleStopScanning}>
                <Text style={styles.secondaryText}>Cancel / Retry</Text>
              </TouchableOpacity>
            </View>
          )}

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
  officerName: { color: "rgba(255,255,255,0.90)", fontSize: 12, fontWeight: "700" },
  badge: { color: "rgba(255,255,255,0.55)", fontSize: 10, marginTop: 2 },
  page: { flexGrow: 1, paddingHorizontal: 18, paddingTop: 18, paddingBottom: 36 },
  stepText: { color: "rgba(255,255,255,0.92)", fontSize: 13, fontWeight: "800", marginBottom: 8 },
  bodyText: { color: "rgba(255,255,255,0.70)", fontSize: 12, lineHeight: 18, marginBottom: 16 },

  // SCANNER STYLES
  imageBox: {
    height: 250, // Taller for camera
    width: "100%",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.12)",
    backgroundColor: "rgba(0,0,0,0.3)",
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 14,
    overflow: "hidden",
  },
  cameraContainer: {
    height: 250,
    width: "100%",
    borderRadius: 12,
    overflow: "hidden",
    marginBottom: 14,
    borderWidth: 1,
    borderColor: "#4DB5FF",
    backgroundColor: "#000",
  },
  overlayLayer: {
    ...StyleSheet.absoluteFillObject,
    justifyContent: "center",
    alignItems: "center",
  },
  scanFrame: {
    width: 180,
    height: 180,
    borderWidth: 2,
    borderColor: "#15C85A",
    borderRadius: 12,
    backgroundColor: "transparent",
  },
  scanText: {
    color: "white",
    marginTop: 10,
    fontSize: 12,
    backgroundColor: "rgba(0,0,0,0.5)",
    paddingHorizontal: 8,
    paddingVertical: 4,
    borderRadius: 4,
  },
  manualModeText: {
    color: "rgba(255,255,255,0.6)",
    marginTop: 10,
    fontSize: 14,
    fontWeight: "600",
  },

  // BTNS & BOXES
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
    alignItems: "center",
    justifyContent: "center",
    marginTop: 10,
  },
  textLinkBtn: {
    padding: 15,
    alignItems: "center",
  },
  textLink: {
    color: "#6DA8FF",
    fontSize: 13,
    textDecorationLine: "underline",
  },
  primaryText: { color: "white", fontSize: 15, fontWeight: "800" },
  secondaryText: { color: "rgba(255,255,255,0.8)", fontSize: 14, fontWeight: "600" },

  // ALERTS
  statusBox: { backgroundColor: "rgba(255,255,255,0.08)", borderRadius: 10, borderWidth: 1, borderColor: "rgba(255,255,255,0.12)", padding: 12, marginBottom: 14, alignItems: "center" },
  statusText: { color: "rgba(255,255,255,0.70)", fontSize: 12 },
  loadingBox: { backgroundColor: "rgba(21,200,90,0.1)", borderRadius: 10, borderWidth: 1, borderColor: "rgba(21,200,90,0.3)", padding: 12, marginBottom: 14, alignItems: "center" },
  loadingText: { color: "#15C85A", fontSize: 13, fontWeight: "600" },
  errorBox: { backgroundColor: "rgba(255,30,30,0.15)", borderRadius: 10, borderWidth: 1, borderColor: "rgba(255,30,30,0.3)", padding: 12, marginBottom: 12 },
  errorText: { color: "rgba(255,150,150,0.90)", fontSize: 11, lineHeight: 16 },
  infoBox: { backgroundColor: "rgba(109,168,255,0.12)", borderRadius: 10, borderWidth: 1, borderColor: "rgba(109,168,255,0.3)", padding: 12, marginBottom: 12, flexDirection: "row", alignItems: "center", gap: 10 },
  infoText: { color: "rgba(109,168,255,0.85)", fontSize: 11, lineHeight: 16, flex: 1 },
  btnIconCircle: { width: 24, height: 24, borderRadius: 12, backgroundColor: "rgba(255,255,255,0.2)", alignItems: "center", justifyContent: "center" },
  footer: { marginTop: 22, alignSelf: "center", color: "rgba(255,255,255,0.25)", fontSize: 10 },
});