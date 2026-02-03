import React, { useEffect, useState, useMemo } from "react";
import { View, Text, StyleSheet, TouchableOpacity, ActivityIndicator } from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";
import { clearPaired, getPaired, setPaired } from "../utils/deviceStore";
import { useAuth } from "../context/AuthContext";
import { supabaseUrl, supabaseAnonKey } from "../lib/supabase";
import { createClient } from "@supabase/supabase-js";

export default function DeviceWelcomeScreen({ navigation }) {
  const { displayName, badge, user } = useAuth(); // Added 'user' to access user_id
  const [paired, setPairedState] = useState(false);
  const [loading, setLoading] = useState(true);

  // Initialize Supabase Client
  const supabase = useMemo(() => createClient(supabaseUrl, supabaseAnonKey), []);

  const load = async () => {
    setLoading(true);

    // 1. Check Local Storage first (Fastest)
    const localPaired = await getPaired();
    if (localPaired) {
      setPairedState(true);
      setLoading(false);
      // Already paired locally, go directly to Home
      navigation.reset({ index: 0, routes: [{ name: "Home" }] });
      return;
    }

    // 2. Check Supabase Cloud Database (If not paired locally)
    if (user?.id) {
      try {
        console.log("[DeviceWelcome] Checking cloud for existing device...");
        const { data, error } = await supabase
          .from("device_credentials")
          .select("id")
          .eq("user_id", user.id)
          .limit(1);

        if (!error && data && data.length > 0) {
          console.log("[DeviceWelcome] Found existing device in cloud. Syncing...");

          // Sync local storage to match cloud status
          await setPaired(true);
          setPairedState(true);

          // Redirect to Home
          navigation.reset({ index: 0, routes: [{ name: "Home" }] });
          return;
        }
      } catch (err) {
        console.warn("[DeviceWelcome] Error checking device status:", err);
      }
    }

    // 3. No device found locally or in cloud
    setPairedState(false);
    setLoading(false);
  };

  useEffect(() => {
    const unsub = navigation.addListener("focus", load);
    return unsub;
  }, [navigation, user]); // Added user dependency

  const handleLogout = async () => {
    await clearPaired();
    navigation.reset({ index: 0, routes: [{ name: "Login" }] });
  };

  const handleAddDevice = () => {
    navigation.navigate("DevicePairingFlow");
  };

  const handleDashboard = () => {
    navigation.navigate("Home");
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

          <TouchableOpacity onPress={handleLogout} activeOpacity={0.8}>
            <Ionicons name="log-out-outline" size={18} color="#FF4A4A" />
          </TouchableOpacity>
        </View>

        <View style={styles.container}>
          <Text style={styles.welcome}>Welcome to E.V.V.O.S</Text>

          <View style={styles.card}>
            {loading ? (
              <ActivityIndicator size="large" color="#4DB5FF" />
            ) : (
              <Ionicons
                name={paired ? "link-outline" : "unlink-outline"}
                size={48}
                color="rgba(0,0,0,0.85)"
              />
            )}
            <Text style={styles.cardText}>
              {loading
                ? "Checking for existing devices..."
                : paired
                  ? "Device is paired."
                  : "Looks like you are not connected to a device."}
            </Text>
          </View>

          {!paired && !loading ? (
            <TouchableOpacity
              style={styles.addBtn}
              activeOpacity={0.9}
              onPress={handleAddDevice}
            >
              <View style={styles.plusCircle}>
                <Ionicons name="add" size={18} color="black" />
              </View>
              <Text style={styles.addBtnText}>Add Device</Text>
            </TouchableOpacity>
          ) : null}

          {paired && !loading ? (
            <TouchableOpacity
              style={styles.dashboardBtn}
              activeOpacity={0.9}
              onPress={handleDashboard}
            >
              <Text style={styles.dashboardText}>Dashboard</Text>
            </TouchableOpacity>
          ) : null}

          <Text style={styles.footer}>
            Public Safety and Traffic Management Department
          </Text>
        </View>
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
  badge: { color: "rgba(255,255,255,0.55)", fontSize: 10, marginTop: 2 },

  container: { flex: 1, paddingHorizontal: 18, paddingTop: 10 },
  welcome: {
    color: "rgba(255,255,255,0.92)",
    fontSize: 24,
    fontWeight: "500",
    marginBottom: 16,
  },

  card: {
    height: 180,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.12)",
    backgroundColor: "rgba(0,0,0,0.15)",
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 16,
  },
  cardText: {
    marginTop: 12,
    color: "rgba(255,255,255,0.70)",
    fontSize: 12,
    textAlign: "center",
    paddingHorizontal: 18,
  },

  addBtn: {
    height: 52,
    borderRadius: 12,
    backgroundColor: "#15C85A",
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 10,
  },
  addBtnText: { color: "white", fontSize: 15, fontWeight: "800" },
  plusCircle: {
    width: 28,
    height: 28,
    borderRadius: 999,
    backgroundColor: "rgba(255,255,255,0.85)",
    alignItems: "center",
    justifyContent: "center",
  },

  dashboardBtn: {
    height: 52,
    borderRadius: 12,
    backgroundColor: "#15C85A",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.12)",
    alignItems: "center",
    justifyContent: "center",
  },
  dashboardText: { color: "white", fontSize: 15, fontWeight: "800" },

  footer: {
    position: "absolute",
    bottom: 14,
    alignSelf: "center",
    color: "rgba(255,255,255,0.25)",
    fontSize: 10,
  },
});