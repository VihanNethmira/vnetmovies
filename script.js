// Demo data (replace with API later)
const MOVIES = [
  {
    id: 6,
    title: "F1: The Movie",
    year: 2025,
    genres: ["Drama", "Thriller", "Sport"],
    rating: 7.7,
    popularity: 70,
    poster: "https://miro.medium.com/v2/resize:fit:640/format:webp/1*KR0XW9mJHCRp9WMlbjvfEw.jpeg",
    overview: "A Formula One driver comes out of retirement to mentor and team up with a younger driver.",
    trailer: "https://megaup.net/3762f4152f285d9856ed4657759f7957/F1_The_Movie_2025_[Uploaded_By_Vihan_Nethmira].mkv"
  }
  
];

const grid = document.getElementById("grid");
const emptyState = document.getElementById("emptyState");
const searchInput = document.getElementById("searchInput");
const genreFilter = document.getElementById("genreFilter");
const yearFilter = document.getElementById("yearFilter");
const sortSelect = document.getElementById("sortSelect");
const yearNow = document.getElementById("yearNow");

const movieModal = document.getElementById("movieModal");
const modalPoster = document.getElementById("modalPoster");
const modalTitle = document.getElementById("modalTitle");
const modalMeta = document.getElementById("modalMeta");
const modalOverview = document.getElementById("modalOverview");
const modalTrailer = document.getElementById("modalTrailer");
const addToWatchlistBtn = document.getElementById("addToWatchlist");
const toggleWatchlistBtn = document.getElementById("toggleWatchlist");
const watchlistItems = document.getElementById("watchlistItems");

let currentList = [...MOVIES];
let selectedMovie = null;
let watchlist = JSON.parse(localStorage.getItem("watchlist") || "[]");

document.addEventListener("DOMContentLoaded", () => {
  yearNow.textContent = new Date().getFullYear();
  hydrateFilters(MOVIES);
  render(MOVIES);
  renderWatchlist();

  // Listeners
  searchInput.addEventListener("input", applyFilters);
  genreFilter.addEventListener("change", applyFilters);
  yearFilter.addEventListener("change", applyFilters);
  sortSelect.addEventListener("change", applyFilters);

  document.querySelector(".close").addEventListener("click", () => movieModal.close());
  movieModal.addEventListener("click", (e) => {
    if (e.target === movieModal) movieModal.close();
  });
  addToWatchlistBtn.addEventListener("click", () => {
    if (!selectedMovie) return;
    addToWatchlist(selectedMovie);
    movieModal.close();
  });

  toggleWatchlistBtn.addEventListener("click", () => {
    const el = document.querySelector(".watchlist");
    el.style.display = el.style.display === "none" ? "block" : "none";
  });
});

function hydrateFilters(data){
  const genres = new Set();
  const years = new Set();
  data.forEach(m => {
    m.genres.forEach(g => genres.add(g));
    years.add(m.year);
  });
  [...genres].sort().forEach(g => {
    const opt = document.createElement("option");
    opt.value = g; opt.textContent = g;
    genreFilter.appendChild(opt);
  });
  [...years].sort((a,b)=>b-a).forEach(y => {
    const opt = document.createElement("option");
    opt.value = y; opt.textContent = y;
    yearFilter.appendChild(opt);
  });
}

function applyFilters(){
  const q = searchInput.value.trim().toLowerCase();
  const g = genreFilter.value;
  const y = yearFilter.value ? Number(yearFilter.value) : null;

  let list = MOVIES.filter(m => {
    const matchQ = !q || m.title.toLowerCase().includes(q) || m.overview.toLowerCase().includes(q);
    const matchG = !g || m.genres.includes(g);
    const matchY = !y || m.year === y;
    return matchQ && matchG && matchY;
  });

  const sort = sortSelect.value;
  list.sort((a,b)=>{
    switch(sort){
      case "popular": return b.popularity - a.popularity;
      case "rating_desc": return b.rating - a.rating;
      case "rating_asc": return a.rating - b.rating;
      case "year_desc": return b.year - a.year;
      case "year_asc": return a.year - b.year;
      case "title_asc": return a.title.localeCompare(b.title);
      case "title_desc": return b.title.localeCompare(a.title);
      default: return 0;
    }
  });

  currentList = list;
  render(list);
}

function render(list){
  grid.innerHTML = "";
  if (!list.length){
    emptyState.hidden = false;
    return;
  }
  emptyState.hidden = true;

  list.forEach(m => {
    const card = document.createElement("article");
    card.className = "card";
    card.innerHTML = `
      <img class="poster" src="${m.poster}" alt="Poster of ${escapeHTML(m.title)}" />
      <div class="card-body">
        <h3 class="title">${escapeHTML(m.title)}</h3>
        <div class="meta">${m.year} • ⭐ ${m.rating} • ${m.genres.join(", ")}</div>
        <div class="tags">
          ${m.genres.map(g=>`<span class="tag">${escapeHTML(g)}</span>`).join("")}
        </div>
      </div>
    `;
    card.addEventListener("click", () => openModal(m));
    grid.appendChild(card);
  });
}

function openModal(movie){
  selectedMovie = movie;
  modalPoster.src = movie.poster;
  modalPoster.alt = `Poster of ${movie.title}`;
  modalTitle.textContent = movie.title;
  modalMeta.textContent = `${movie.year} • ⭐ ${movie.rating} • ${movie.genres.join(", ")}`;
  modalOverview.textContent = movie.overview;
  modalTrailer.href = movie.trailer;
  modalTrailer.textContent = "Download";
  if (typeof movieModal.showModal === "function"){
    movieModal.showModal();
  } else {
    // Fallback if <dialog> unsupported
    movieModal.setAttribute("open", "");
  }
}

function addToWatchlist(movie){
  if (watchlist.some(m => m.id === movie.id)) return;
  watchlist.push(movie);
  localStorage.setItem("watchlist", JSON.stringify(watchlist));
  renderWatchlist();
}

function removeFromWatchlist(id){
  watchlist = watchlist.filter(m => m.id !== id);
  localStorage.setItem("watchlist", JSON.stringify(watchlist));
  renderWatchlist();
}

function renderWatchlist(){
  watchlistItems.innerHTML = "";
  if (!watchlist.length){
    const li = document.createElement("li");
    li.textContent = "No items yet.";
    watchlistItems.appendChild(li);
    return;
  }
  watchlist.forEach(m => {
    const li = document.createElement("li");
    li.innerHTML = `
      <img src="${m.poster}" alt="Poster" />
      <span>${escapeHTML(m.title)} (${m.year})</span>
      <button class="btn small remove">Remove</button>
    `;
    li.querySelector(".remove").addEventListener("click", () => removeFromWatchlist(m.id));
    watchlistItems.appendChild(li);
  });
}

// Utilities
function escapeHTML(str){
  return str.replace(/[&<>"']/g, s => ({
    "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"
  }[s]));
}