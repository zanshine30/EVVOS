import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  TextInput,
  ActivityIndicator,
  ScrollView,
} from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";
import { setPaired } from "../utils/deviceStore";
import { useAuth } from "../context/AuthContext";

export default function DevicePairingFlowScreen({ navigation }) {
  const { displayName, badge } = useAuth();
  const [step, setStep] = useState(1); // 1..6
  const [ssid, setSsid] = useState("");
  const [pw, setPw] = useState("");
  const [showPw, setShowPw] = useState(false);
  const timerRef = useRef(null);

  const steps = useMemo(
    () => [
      {
        id: 1,
        title: "Step 1",
        body: "Turn on the E.V.V.O.S device by pressing and holding the button for 5 seconds.",
        icon: "power-outline",
      },
      {
        id: 2,
        title: "Step 2",
        body:
          "Go to your mobile phone’s Wi-Fi settings and connect to your E.V.V.O.S device network: Evvos_XXXX (XXXX is the last four digits).",
        icon: "wifi-outline",
      },
      {
        id: 3,
        title: "Step 3",
        body:
          "After connecting to the E.V.V.O.S device, go to your hotspot settings, add a password (if not already), and turn it on.",
        icon: "cellular-outline",
      },
    ],
    []
  );

  useEffect(() => {
    if (step === 5) {
      timerRef.current = setTimeout(async () => {
        await setPaired(true);
        setStep(6);
      }, 2200);
    }
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, [step]);

  const goNext = () => {
    if (step < 6) setStep((s) => s + 1);
  };

  const goDashboard = () => {
    navigation.reset({
      index: 0,
      routes: [{ name: "Home" }],
    });
  };

  const renderContent = () => {
    if (step >= 1 && step <= 3) {
      const s = steps.find((x) => x.id === step);
      return (
        <>
          <Text style={styles.stepText}>{s.title}</Text>
          <Text style={styles.bodyText}>{s.body}</Text>

          <View style={styles.imageBox}>
            <Ionicons name={s.icon} size={64} color="rgba(255,255,255,0.85)" />
          </View>

          <Text style={styles.hintText}>
            {step === 1
              ? "Is your E.V.V.O.S device ready to pair?"
              : step === 2
              ? "Already connected to the device’s network?"
              : "Done configuring portable hotspot?"}
          </Text>
              
          <TouchableOpacity style={styles.primaryBtn} activeOpacity={0.9} onPress={goNext}>
            <View style={styles.btnIconCircle}>
            <Ionicons name="chevron-forward" size={25} color="white" />
          </View>
            <Text style={styles.primaryText}>Next</Text>
          </TouchableOpacity>
        </>
      );
    }

    if (step === 4) {
      return (
        <>
          <Text style={styles.stepText}>Step 4</Text>
          <Text style={styles.bodyText}>
            Enter your hotspot SSID and password. The device will connect and pair automatically.
          </Text>

          <Text style={styles.label}>Hotspot SSID</Text>
          <View style={styles.inputWrap}>
            <TextInput
              value={ssid}
              onChangeText={setSsid}
              placeholder="Enter SSID"
              placeholderTextColor="rgba(255,255,255,0.35)"
              style={styles.input}
            />
          </View>

          <Text style={[styles.label, { marginTop: 10 }]}>Hotspot Password</Text>
          <View style={styles.inputWrap}>
            <TextInput
              value={pw}
              onChangeText={setPw}
              placeholder="Enter password"
              placeholderTextColor="rgba(255,255,255,0.35)"
              secureTextEntry={!showPw}
              style={styles.input}
            />
            <TouchableOpacity onPress={() => setShowPw((v) => !v)} activeOpacity={0.8}>
              <Ionicons
                name={showPw ? "eye-off-outline" : "eye-outline"}
                size={16}
                color="rgba(255,255,255,0.55)"
              />
            </TouchableOpacity>
          </View>

          <Text style={styles.smallNote}>Case and space sensitive</Text>
          <Text style={styles.hintText}>Make sure the SSID and password are correct.</Text>

          <TouchableOpacity style={styles.primaryBtn} activeOpacity={0.9} onPress={() => setStep(5)}>
            <View style={styles.btnIconCircle}>
            <Ionicons name="chevron-forward" size={25} color="white" />
            </View>
            <Text style={styles.primaryText}>Pair Device</Text>
          </TouchableOpacity>
        </>
      );
    }

    if (step === 5) {
      return (
        <View style={{ alignItems: "center", marginTop: 34 }}>
          <Text style={styles.pairingTitle}>Device pairing…</Text>

          <View style={[styles.imageBox, { marginTop: 18 }]}>
            <Ionicons name="globe-outline" size={92} color="rgba(255,255,255,0.85)" />
          </View>

          <ActivityIndicator size="large" color="#15C85A" style={{ marginTop: 18 }} />
        </View>
      );
    }

    return (
      <View style={{ alignItems: "center", marginTop: 34 }}>
        <Text style={styles.pairingTitle}>Device Paired</Text>

        <View style={[styles.imageBox, { marginTop: 18 }]}>
          <Ionicons name="flash-outline" size={80} color="rgba(255,255,255,0.85)" />
        </View>

        <TouchableOpacity
          style={[styles.primaryBtn, { marginTop: 22 }]}
          activeOpacity={0.9}
          onPress={goDashboard}
        >
          <View style={styles.btnIconCircle}>
            <Ionicons name="chevron-forward" size={25} color="white" />
          </View>
          <Text style={styles.primaryText}>Go to Dashboard</Text>
        </TouchableOpacity>
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
              <Text style={styles.badge}>{badge ? `Badge #${badge}` : ''}</Text>
            </View>
          </View>

          <TouchableOpacity activeOpacity={0.9} onPress={() => navigation.goBack()}>
            
            <Ionicons name="arrow-back" size={18} color="rgba(255,255,255,0.😎" />
          </TouchableOpacity>
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
  officerName: { color: "rgba(255,255,255,0.90)", fontSize: 12, fontWeight: "700" },
  badge: { color: "rgba(255,255,255,0.55)", fontSize: 10, marginTop: 2 },

  page: { flexGrow: 1, paddingHorizontal: 18, paddingTop: 18, paddingBottom: 36 },

  stepText: { color: "rgba(255,255,255,0.92)", fontSize: 13, fontWeight: "800", marginBottom: 8 },
  bodyText: { color: "rgba(255,255,255,0.70)", fontSize: 12, lineHeight: 18, marginBottom: 16 },

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

  hintText: { color: "rgba(255,255,255,0.45)", fontSize: 11, marginTop: 6, marginBottom: 12 },

  primaryBtn: {
    height: 50,
    width: "100%",
    borderRadius: 12,
    backgroundColor: "#15C85A",
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 10,
  },
 
  primaryText: { color: "white", fontSize: 15, fontWeight: "800" },

  label: { color: "rgba(255,255,255,0.55)", fontSize: 11, marginBottom: 6 },
  inputWrap: {
    height: 44,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
    backgroundColor: "rgba(255,255,255,0.06)",
    paddingHorizontal: 12,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
  },
  input: { color: "rgba(255,255,255,0.90)", fontSize: 12, flex: 1, paddingRight: 10 },
  smallNote: { color: "rgba(255,255,255,0.35)", fontSize: 10, marginTop: 6 },

  pairingTitle: { color: "rgba(255,255,255,0.92)", fontSize: 20, fontWeight: "600" },

  footer: { marginTop: 22, alignSelf: "center", color: "rgba(255,255,255,0.25)", fontSize: 10 },
});