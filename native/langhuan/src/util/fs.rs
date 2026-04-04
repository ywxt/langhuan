use std::path::Path;

pub async fn write_atomic(path: &Path, content: &str) -> std::io::Result<()> {
    let mut tmp_path = path.to_path_buf();
    let ext = path
        .extension()
        .and_then(|s| s.to_str())
        .map(|ext| format!("{ext}.tmp"))
        .unwrap_or_else(|| "tmp".to_owned());
    tmp_path.set_extension(ext);

    tokio::fs::write(&tmp_path, content).await?;

    if let Err(rename_err) = tokio::fs::rename(&tmp_path, path).await {
        #[cfg(windows)]
        {
            if path.exists() {
                tokio::fs::remove_file(path).await?;
                tokio::fs::rename(&tmp_path, path).await?;
                return Ok(());
            }
        }

        let _ = tokio::fs::remove_file(&tmp_path).await;
        return Err(rename_err);
    }

    Ok(())
}
