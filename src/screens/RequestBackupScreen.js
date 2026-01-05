import React, { useMemo, useState } from "react";
import { View, Text, StyleSheet, TouchableOpacity, ScrollView } from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";

export default function RequestBackupScreen({ navigation }) {
  const [responders] = useState(4);

  const backupData = useMemo(
    () => ({
      enforcer: "Juan Bartolome",
      location: "Llano Rd., Caloocan City",
      time: "8:21 pm",
      responders,
      coords: { latitude: 14.7566, longitude: 121.0447 },
    }),
    [responders]
  );

  const handleConfirm = () => {
    navigation.navigate("Recording", { backupData });
  };

  return (
    <LinearGradient
      colors={["#0B1A33", "#3D5F91"]}
      start={{ x: 0.5, y: 0 }}
      end={{ x: 0.5, y: 1 }}
      style={styles.gradient}
    >
      <SafeAreaView style={styles.safe}>
        <ScrollView
          contentContainerStyle={styles.scroll}
          showsVerticalScrollIndicator={false}
          alwaysBounceVertical={false}
        >
          <View style={styles.headerRow}>
            <Text style={styles.headerTitle}>Request Backup</Text>
          </View>

          <View style={styles.card}>
            <View style={styles.cardTitleRow}>
              <Ionicons name="alert-circle-outline" size={18} color="#FF4A4A" />
              <Text style={styles.cardTitle}>Backup Request Details</Text>
            </View>

            <View style={styles.row}>
              <Text style={styles.label}>Enforcer</Text>
              <Text style={styles.value}>{backupData.enforcer}</Text>
            </View>

            <View style={styles.row}>
              <Text style={styles.label}>Location</Text>
              <Text style={styles.value}>{backupData.location}</Text>
            </View>

            <View style={styles.row}>
              <Text style={styles.label}>Time</Text>
              <Text style={styles.value}>{backupData.time}</Text>
            </View>

            <View style={styles.row}>
              <Text style={styles.label}>No. of Responders/</Text>
              <Text style={styles.value}>{backupData.responders}</Text>
            </View>

            <TouchableOpacity style={styles.confirmBtn} activeOpacity={0.9} onPress={handleConfirm}>
              <Text style={styles.confirmText}>CONFIRM</Text>
            </TouchableOpacity>
          </View>

          <TouchableOpacity
            style={styles.backBtn}
            activeOpacity={0.9}
            onPress={() => navigation.goBack()}
          >
            <Ionicons name="chevron-back" size={16} color="rgba(255,255,255,0.85)" />
            <Text style={styles.backText}>Back</Text>
          </TouchableOpacity>
        </ScrollView>
      </SafeAreaView>
    </LinearGradient>
  );
}

const styles = StyleSheet.create({
  gradient: { flex: 1 },
  safe: { flex: 1 },
  scroll: {
    flexGrow: 1,
    paddingHorizontal: 18,
    paddingTop: 10,
    paddingBottom: 18,
  },
  headerRow: { alignItems: "center", marginBottom: 14 },
  headerTitle: {
    color: "rgba(255,255,255,0.90)",
    fontSize: 14,
    fontWeight: "700",
    letterSpacing: 0.4,
  },
  card: {
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 14,
    borderWidth: 1,
    borderColor: "rgba(61,220,132,0.25)",
    padding: 14,
  },
  cardTitleRow: { flexDirection: "row", alignItems: "center", marginBottom: 10 },
  cardTitle: {
    marginLeft: 8,
    color: "rgba(255,255,255,0.88)",
    fontSize: 13,
    fontWeight: "700",
  },
  row: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingVertical: 10,
    borderBottomWidth: 1,
    borderBottomColor: "rgba(255,255,255,0.08)",
  },
  label: { color: "rgba(255,255,255,0.60)", fontSize: 12 },
  value: { color: "rgba(255,255,255,0.90)", fontSize: 12, fontWeight: "700" },

  confirmBtn: {
    marginTop: 14,
    backgroundColor: "#3DDC84",
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: "center",
  },
  confirmText: {
    color: "rgba(15,25,45,0.95)",
    fontSize: 12,
    fontWeight: "900",
    letterSpacing: 0.8,
  },

  backBtn: {
    marginTop: 12,
    alignSelf: "flex-start",
    flexDirection: "row",
    alignItems: "center",
    paddingVertical: 10,
    paddingHorizontal: 10,
    borderRadius: 10,
    backgroundColor: "rgba(0,0,0,0.14)",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
  },
  backText: { marginLeft: 6, color: "rgba(255,255,255,0.85)", fontSize: 12, fontWeight: "700" },
});