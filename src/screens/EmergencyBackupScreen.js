import React, { useMemo, useState, useEffect } from "react";
import { View, Text, StyleSheet, TouchableOpacity } from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import MapView, { Marker } from "react-native-maps";
import { SafeAreaView } from "react-native-safe-area-context";
import supabase from '../lib/supabase';

export default function EmergencyBackupScreen({ navigation, route }) {
  const [backupData, setBackupData] = useState(route?.params?.backupData);
  const [status, setStatus] = useState("En Route"); // "On Scene"

  useEffect(() => {
    if (route?.params?.request_id && !backupData) {
      const fetchData = async () => {
        const { data, error } = await supabase.from('emergency_backups').select('*').eq('request_id', route.params.request_id).single();
        if (!error && data) {
          setBackupData({
            enforcer: data.enforcer,
            location: data.location,
            time: data.time,
            responders: data.responders,
            coords: { latitude: 14.7566, longitude: 121.0447 },
            request_id: data.request_id
          });
        }
      };
      fetchData();
    }
  }, [route?.params?.request_id, backupData]);

  const coords = backupData?.coords || { latitude: 14.7566, longitude: 121.0447 };
  const name = backupData?.enforcer ?? "Juan Bartolome";
  const location = backupData?.location ?? "Llano Rd., Caloocan City";
  const time = backupData?.time ?? "8:21 pm";
  const responders = backupData?.responders ?? 4;
  const requestId = backupData?.request_id;

  return (
    <LinearGradient
      colors={["#0B1A33", "#3D5F91"]}
      start={{ x: 0.5, y: 0 }}
      end={{ x: 0.5, y: 1 }}
      style={styles.gradient}
    >
      <SafeAreaView style={styles.safe}>
        <View style={styles.container}>
          <View style={styles.topHeader}>
            <Text style={styles.headerTitle}>Emergency Backup</Text>
          </View>

          
          <View style={[styles.card, styles.cardGreen]}>
            <View style={styles.cardHeaderRow}>
              <View style={[styles.pill, styles.pillGreen]}>
                <Text style={styles.pillText}>REQUEST</Text>
              </View>
              <Ionicons name="shield-checkmark-outline" size={18} color="#17F39A" />
            </View>

            <Text style={styles.line}>
              Name: <Text style={styles.value}>{name}</Text>
            </Text>
            <Text style={styles.line}>
              Location: <Text style={styles.value}>{location}</Text>
            </Text>
            <Text style={styles.line}>
              Time: <Text style={styles.value}>{time}</Text>
            </Text>
            <Text style={styles.line}>
              No. of Responders/: <Text style={styles.value}>{responders}</Text>
            </Text>
          </View>

          
          <View style={[styles.card, styles.cardBlue]}>
            <View style={styles.cardHeaderRow}>
              <View style={[styles.pill, styles.pillBlue]}>
                <Text style={styles.pillText}>LOCATION</Text>
              </View>
              <Ionicons name="location-outline" size={18} color="#FF4A4A" />
            </View>

            <View style={styles.mapWrap}>
              <MapView
                style={styles.map}
                initialRegion={{
                  ...coords,
                  latitudeDelta: 0.01,
                  longitudeDelta: 0.01,
                }}
              >
                <Marker coordinate={coords} />
              </MapView>
            </View>

            <TouchableOpacity style={styles.viewLocationBtn} activeOpacity={0.9}>
              <Text style={styles.viewLocationText}>View Location</Text>
            </TouchableOpacity>
          </View>

         
          <View style={[styles.card, styles.cardGreen]}>
            <View style={styles.cardHeaderRow}>
              <View style={[styles.pill, styles.pillGreen]}>
                <Text style={styles.pillText}>STATUS</Text>
              </View>
              <Ionicons name="pulse-outline" size={18} color="rgba(255,255,255,0.85)" />
            </View>

            <View style={styles.statusRow}>
              <TouchableOpacity
                style={[styles.statusBtn, status === "En Route" && styles.statusBtnActive]}
                onPress={() => setStatus("En Route")}
                activeOpacity={0.9}
              >
                <Text style={[styles.statusText, status === "En Route" && styles.statusTextActive]}>
                  En Route
                </Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={[styles.statusBtn, status === "On Scene" && styles.statusBtnActive]}
                onPress={() => setStatus("On Scene")}
                activeOpacity={0.9}
              >
                <Text style={[styles.statusText, status === "On Scene" && styles.statusTextActive]}>
                  On Scene
                </Text>
              </TouchableOpacity>
            </View>
          </View>

          
          <View style={styles.bottomRow}>
            <TouchableOpacity
              style={[styles.bottomBtn, styles.resolved]}
              activeOpacity={0.9}
              onPress={async () => {
                if (requestId) {
                  try {
                    await supabase.from('emergency_backups').update({ status: 'RESOLVED' }).eq('request_id', requestId);
                  } catch (err) {
                    console.error('Failed to update status:', err);
                  }
                }
                navigation.reset({
                  index: 0,
                  routes: [{ name: "Home" }], // ✅ goes back to Home screen
                });
              }}
            >
              <Text style={styles.bottomTextDark}>RESOLVED</Text>
            </TouchableOpacity>

            <TouchableOpacity
              style={[styles.bottomBtn, styles.cancel]}
              activeOpacity={0.9}
              onPress={() => navigation.goBack()}
            >
              <Text style={styles.bottomText}>CANCEL</Text>
            </TouchableOpacity>
          </View>
        </View>
      </SafeAreaView>
    </LinearGradient>
  );
}

const styles = StyleSheet.create({
  gradient: { flex: 1 },
  safe: { flex: 1 },

  container: {
    flex: 1,
    paddingHorizontal: 18,
    paddingTop: 6,
    paddingBottom: 18,
    gap: 12,
  },

  topHeader: { alignItems: "center", marginBottom: 6 },
  headerTitle: { color: "rgba(255,255,255,0.90)", fontSize: 13, fontWeight: "700" },

  card: {
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    borderWidth: 1,
    padding: 12,
  },
  cardGreen: { borderColor: "rgba(61,220,132,0.35)" },
  cardBlue: { borderColor: "rgba(120,170,255,0.30)" },

  cardHeaderRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: 10,
  },

  pill: { paddingHorizontal: 10, paddingVertical: 6, borderRadius: 999, borderWidth: 1 },
  pillGreen: { backgroundColor: "rgba(23,243,154,0.10)", borderColor: "rgba(23,243,154,0.35)" },
  pillBlue: { backgroundColor: "rgba(120,170,255,0.10)", borderColor: "rgba(120,170,255,0.35)" },
  pillText: { color: "rgba(255,255,255,0.90)", fontSize: 11, fontWeight: "800", letterSpacing: 0.3 },

  line: { color: "rgba(255,255,255,0.65)", fontSize: 12, marginTop: 6 },
  value: { color: "rgba(255,255,255,0.90)", fontWeight: "800" },

  mapWrap: {
    height: 190,
    borderRadius: 12,
    overflow: "hidden",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
  },
  map: { flex: 1 },

  viewLocationBtn: {
    marginTop: 10,
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.12)",
    paddingVertical: 12,
    alignItems: "center",
  },
  viewLocationText: { color: "rgba(255,255,255,0.85)", fontSize: 12, fontWeight: "800" },

  statusRow: { flexDirection: "row", gap: 10, marginTop: 4 },
  statusBtn: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.12)",
    paddingVertical: 12,
    alignItems: "center",
  },
  statusBtnActive: {
    backgroundColor: "rgba(23,243,154,0.10)",
    borderColor: "rgba(23,243,154,0.35)",
  },
  statusText: { color: "rgba(255,255,255,0.65)", fontSize: 12, fontWeight: "800" },
  statusTextActive: { color: "rgba(255,255,255,0.92)" },

  bottomRow: { marginTop: "auto", flexDirection: "row", gap: 10 },
  bottomBtn: { flex: 1, borderRadius: 12, paddingVertical: 14, alignItems: "center" },
  resolved: { backgroundColor: "#3DDC84" },
  cancel: { backgroundColor: "#FF1E1E" },
  bottomText: { color: "white", fontSize: 12, fontWeight: "900", letterSpacing: 0.5 },
  bottomTextDark: { color: "rgba(15,25,45,0.95)", fontSize: 12, fontWeight: "900", letterSpacing: 0.5 },
});