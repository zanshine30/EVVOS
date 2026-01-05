import React, { useEffect, useState } from "react";
import { View, Text, StyleSheet, TouchableOpacity } from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";
import { clearPaired, getPaired } from "../utils/deviceStore";

export default function DeviceWelcomeScreen({ navigation }) {
  const [paired, setPairedState] = useState(false);
  const [loading, setLoading] = useState(true);

  const load = async () => {
    setLoading(true);
    const p = await getPaired();
    setPairedState(!!p);
    setLoading(false);
  };

  useEffect(() => {
    const unsub = navigation.addListener("focus", load);
    return unsub;
  }, [navigation]);

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
              <Text style={styles.officerName}>Officer Marcus Rodriguez</Text>
              <Text style={styles.badge}>Badge #4521</Text>
            </View>
          </View>

     
          <TouchableOpacity onPress={handleLogout} activeOpacity={0.8}>
            <Ionicons name="log-out-outline" size={18} color="#FF4A4A" />
          </TouchableOpacity>
        </View>

        <View style={styles.container}>
          <Text style={styles.welcome}>Welcome to E.V.V.O.S</Text>

          <View style={styles.card}>
            <Ionicons
              name={paired ? "link-outline" : "unlink-outline"}
              size={48}
              color="rgba(0,0,0,0.85)"
            />
            <Text style={styles.cardText}>
              {loading
                ? "Checking device status..."
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