import React, { useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  Image,
  TextInput,
  TouchableOpacity,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  Alert,
} from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";

export default function CreateNewPasswordScreen({ navigation }) {
  const [newPassword, setNewPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [showNew, setShowNew] = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);

  const handleConfirm = () => {
    if (!newPassword || !confirmPassword) {
      Alert.alert("Missing Fields", "Please fill in both password fields.");
      return;
    }
    if (newPassword.length < 6) {
      Alert.alert("Weak Password", "Password must be at least 6 characters.");
      return;
    }
    if (newPassword !== confirmPassword) {
      Alert.alert("Mismatch", "Passwords do not match.");
      return;
    }

  
    Alert.alert("Success", "Your password has been updated.", [
      {
        text: "OK",
        onPress: () => navigation.reset({ index: 0, routes: [{ name: "Login" }] }),
      },
    ]);
  };

  return (
    <LinearGradient
      colors={["#0B1A33", "#3D5F91"]}
      start={{ x: 0.5, y: 0 }}
      end={{ x: 0.5, y: 1 }}
      style={styles.gradient}
    >
      <KeyboardAvoidingView
        style={styles.flex}
        behavior={Platform.OS === "ios" ? "padding" : undefined}
      >
        <ScrollView contentContainerStyle={styles.scroll} keyboardShouldPersistTaps="handled">
         
          <View style={styles.header}>
            <Image
              source={require("../../assets/logo.png")}
              style={styles.logo}
              resizeMode="contain"
            />
            <Text style={styles.title}>E.V.V.O.S.</Text>
            <Text style={styles.subtitle}>
              Enforcer Voice-activated Video Observation System
            </Text>
          </View>

        
          <View style={styles.card}>
            <View style={styles.cardTop}>
              <TouchableOpacity
                onPress={() => navigation.goBack()}
                style={styles.backBtn}
                activeOpacity={0.7}
              >
                <Ionicons name="chevron-back" size={22} color="rgba(255,255,255,0.85)" />
              </TouchableOpacity>

              <Text style={styles.cardTitle}>Create New Password</Text>
              <View style={{ width: 36 }} />
            </View>

            <View style={styles.cardBody}>
              <Text style={styles.info}>Please write your new password.</Text>

              <Text style={[styles.label, { marginTop: 10 }]}>New password</Text>
              <View style={styles.inputWrap}>
                <TextInput
                  value={newPassword}
                  onChangeText={setNewPassword}
                  placeholder="Enter password"
                  placeholderTextColor="rgba(255,255,255,0.45)"
                  style={styles.input}
                  secureTextEntry={!showNew}
                  autoCapitalize="none"
                  autoCorrect={false}
                />
                <TouchableOpacity
                  onPress={() => setShowNew((v) => !v)}
                  style={styles.eyeBtn}
                  activeOpacity={0.7}
                >
                  <Ionicons
                    name={showNew ? "eye" : "eye-off"}
                    size={20}
                    color="rgba(255,255,255,0.75)"
                  />
                </TouchableOpacity>
              </View>

              <Text style={[styles.label, { marginTop: 12 }]}>Confirm password</Text>
              <View style={styles.inputWrap}>
                <TextInput
                  value={confirmPassword}
                  onChangeText={setConfirmPassword}
                  placeholder="Confirm password"
                  placeholderTextColor="rgba(255,255,255,0.45)"
                  style={styles.input}
                  secureTextEntry={!showConfirm}
                  autoCapitalize="none"
                  autoCorrect={false}
                />
                <TouchableOpacity
                  onPress={() => setShowConfirm((v) => !v)}
                  style={styles.eyeBtn}
                  activeOpacity={0.7}
                >
                  <Ionicons
                    name={showConfirm ? "eye" : "eye-off"}
                    size={20}
                    color="rgba(255,255,255,0.75)"
                  />
                </TouchableOpacity>
              </View>

              <TouchableOpacity onPress={handleConfirm} style={styles.primaryBtn} activeOpacity={0.85}>
                <Text style={styles.primaryText}>Confirm</Text>
              </TouchableOpacity>
            </View>
          </View>

          <Text style={styles.footer}>
            Public Safety and Traffic Management Department
          </Text>
        </ScrollView>
      </KeyboardAvoidingView>
    </LinearGradient>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  gradient: { flex: 1 },
  scroll: {
    flexGrow: 1,
    justifyContent: "center",
    paddingHorizontal: 22,
    paddingVertical: 28,
  },

  header: { alignItems: "center", marginBottom: 18 },
  logo: { width: 105, height: 105, marginBottom: 10 },
  title: {
    color: "white",
    fontSize: 26,
    fontWeight: "700",
    letterSpacing: 1.5,
    marginTop: 2,
  },
  subtitle: {
    color: "rgba(255,255,255,0.65)",
    fontSize: 12,
    marginTop: 8,
    textAlign: "center",
    maxWidth: 280,
    lineHeight: 16,
  },

  card: {
    backgroundColor: "rgba(0,0,0,0.15)",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.18)",
    overflow: "hidden",
  },
  cardTop: {
    height: 44,
    backgroundColor: "rgba(0,0,0,0.18)",
    borderBottomWidth: 1,
    borderBottomColor: "rgba(255,255,255,0.18)",
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 8,
  },
  backBtn: {
    width: 36,
    height: 36,
    alignItems: "center",
    justifyContent: "center",
  },
  cardTitle: { color: "rgba(255,255,255,0.9)", fontSize: 13, fontWeight: "600" },

  cardBody: { padding: 14 },

  info: { color: "rgba(255,255,255,0.65)", fontSize: 11, lineHeight: 15 },

  label: { color: "rgba(255,255,255,0.75)", fontSize: 12, marginBottom: 8 },

  inputWrap: {
    backgroundColor: "rgba(255,255,255,0.10)",
    borderRadius: 10,
    height: 46,
    justifyContent: "center",
    paddingHorizontal: 14,
  },
  input: { color: "white", fontSize: 14, paddingRight: 34 },
  eyeBtn: {
    position: "absolute",
    right: 10,
    height: 46,
    width: 40,
    alignItems: "center",
    justifyContent: "center",
  },

  primaryBtn: {
    marginTop: 14,
    backgroundColor: "#2E78E6",
    height: 46,
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center",
  },
  primaryText: { color: "white", fontSize: 13, fontWeight: "600" },

  footer: {
    marginTop: 16,
    textAlign: "center",
    color: "rgba(255,255,255,0.55)",
    fontSize: 11,
  },
});
