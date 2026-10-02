import { useState } from "react";
import "./App.css";

function App() {
  const languages = [
    "English",
    "Tamil",
    "Hindi",
    "Telugu",
    "Malayalam",
    "Kannada",
    "Bengali",
    "Marathi",
    "Gujarati",
    "Punjabi",
    "Urdu",
    "Spanish",
    "French",
    "German",
    "Italian",
    "Portuguese",
    "Japanese",
    "Korean",
    "Chinese",
    "Arabic",
    "Russian",
  ];

  const [fromLanguage, setFromLanguage] = useState("English");
  const [toLanguage, setToLanguage] = useState("Tamil");
  const [text, setText] = useState("");
  const [translatedText, setTranslatedText] = useState("");
  const [loading, setLoading] = useState(false);

  const translateText = async () => {
    if (!text.trim()) {
      setTranslatedText("Please enter some text to translate.");
      return;
    }

    setLoading(true);
    setTranslatedText("");

    try {
      const response = await fetch("http://localhost:8080/translate", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          text: text,
          sourceLang: fromLanguage,
          targetLang: toLanguage,
        }),
      });

      if (!response.ok) {
        throw new Error("Translation request failed");
      }

      const data = await response.json();

      setTranslatedText(data.translation);
    } catch (error) {
      console.error(error);
      setTranslatedText(
          "Unable to connect to the translation server."
      );
    } finally {
      setLoading(false);
    }
  };

  const swapLanguages = () => {
    setFromLanguage(toLanguage);
    setToLanguage(fromLanguage);
    setTranslatedText("");
  };

  return (
      <div className="app">
        <h1>🌐 Language Translator</h1>

        <p>Translate words, sentences, and paragraphs</p>

        <div className="translator-container">

          <div className="language-row">

            <select
                value={fromLanguage}
                onChange={(e) => setFromLanguage(e.target.value)}
            >
              {languages.map((language) => (
                  <option key={language} value={language}>
                    {language}
                  </option>
              ))}
            </select>

            <button
                className="swap-button"
                onClick={swapLanguages}
            >
              ⇄
            </button>

            <select
                value={toLanguage}
                onChange={(e) => setToLanguage(e.target.value)}
            >
              {languages.map((language) => (
                  <option key={language} value={language}>
                    {language}
                  </option>
              ))}
            </select>

          </div>

          <div className="translation-box">

            <div className="input-section">
              <h3>{fromLanguage}</h3>

              <textarea
                  value={text}
                  onChange={(e) => setText(e.target.value)}
                  placeholder={`Type your ${fromLanguage} text or paragraph here...`}
              />
            </div>

            <div className="output-section">
              <h3>{toLanguage}</h3>

              <div className="translated-text">
                {loading
                    ? "Translating..."
                    : translatedText ||
                    `Your ${toLanguage} translation will appear here...`}
              </div>
            </div>

          </div>

          <button
              className="translate-button"
              onClick={translateText}
              disabled={loading}
          >
            {loading ? "Translating..." : "Translate"}
          </button>

        </div>
      </div>
  );
}

export default App;