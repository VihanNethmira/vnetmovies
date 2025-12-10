// Demo data (replace with API later)
const MOVIES = [
  {
    id: 1,
    title: "F1: The Movie",
    year: 2025,
    genres: ["Drama", "Thriller", "Sport"],
    rating: 7.7,
    popularity: 70,
    poster: "https://miro.medium.com/v2/resize:fit:640/format:webp/1*KR0XW9mJHCRp9WMlbjvfEw.jpeg",
    overview: "A Formula One driver comes out of retirement to mentor and team up with a younger driver.",
    trailer: "https://megaup.net/70b154a106f62fff1fdc726e504aa1cb/F1_The_Movie_2025_[VNET_MOVIES].mkv"
  },
  {
    id: 2,
    title: "127 Hours",
    year: 2010,
    genres: ["Thriller", "Adventure"],
    rating: 7.5,
    popularity: 2492,
    poster: "https://upload.wikimedia.org/wikipedia/en/b/b3/127_Hours_Poster.jpg",
    overview: "A mountain climber becomes trapped under a boulder while canyoneering alone near Moab, Utah and resorts to desperate measures in order to survive.",
    trailer: "https://megaup.net/d62cd73e71aa426205ee85257954244b/127_Hours_2010_[VNET_MOVIES].mkv"
  },
  {
    id: 3,
    title: "The Conjuring: Last Rites",
    year: 2025,
    genres: ["Horror "],
    rating: 7.5,
    popularity: 100,
    poster: "https://play-lh.googleusercontent.com/UkmdZlGJu-qcy3ue7IidfF2l3WD9BbNPcchOToBnYQHg6zORNuPSFKy5Xt8NbYQ7MpxyZz1KaBt7AJV5yoVB=w240-h480-rw",
    overview: "Paranormal investigators Ed and Lorraine Warren take on one last terrifying case involving mysterious entities they must confront.",
    trailer: "https://megaup.net/f4454bebd0135e1c553104e5c23eefa1/The_Conjuring_Last_Rites_2025_[VNET_MOVIES].mkv"
  },
  {
    id: 4,
    title: "Interstellar",
    year: 2014,
    genres: ["Sci-fi", "Adventure"],
    rating: 8.7,
    popularity: 93,
    poster: "https://m.media-amazon.com/images/M/MV5BYzdjMDAxZGItMjI2My00ODA1LTlkNzItOWFjMDU5ZDJlYWY3XkEyXkFqcGc@._V1_FMjpg_UX1000_.jpg",
    overview: "When Earth becomes uninhabitable in the future, a farmer and ex-NASA pilot, Joseph Cooper, is tasked to pilot a spacecraft, along with a team of researchers, to find a new planet for humans.",
    trailer: "https://megaup.net/33e115609983bdfacf256f8619bed8fe/Interstellar_2014_[VNET_MOVIES].mkv"
  },
  {
    id: 5,
    title: "Inception: Jump Right Into the Action",
    year: 2010,
    genres: ["Sci-fi", "Action"],
    rating: 8.8,
    popularity: 93,
    poster: "https://m.media-amazon.com/images/M/MV5BZjhkNjM0ZTMtNGM5MC00ZTQ3LTk3YmYtZTkzYzdiNWE0ZTA2XkEyXkFqcGc@._V1_.jpg",
    overview: "Join filmmaker Christopher Nolan and his cast and crew as they reveal the secrets of Inception, its development, characters, performances, story and jaw-dropping special effects in this solid 14-segments piece.",
    trailer: "https://megaup.net/62121beef261472228174fab5f2df757/Inception_2010_[VNET_MOVIES].mkv"
  },
  {
    id: 6,
    title: "Jurassic World: Rebirth",
    year: 2025,
    genres: ["Sci-fi", "Action"],
    rating: 8,
    popularity: 89,
    poster: "https://play-lh.googleusercontent.com/hoXWWwTBGZIdrOklQPlgtAXBtI5TDA3GqDuH-cdsABxNTM-wMVFzl8vRwctkUPs05h9iIRN-Oa68Foh_RQ",
    overview: "Five years post-Jurassic World: Dominion (2022), an expedition braves isolated equatorial regions to extract DNA from three massive prehistoric creatures for a groundbreaking medical breakthrough.",
    trailer: "https://megaup.net/d3133d09b80dcf862900a2ddb41a7570/Jurassic_World_Rebirth_2025_[VNET_MOVIES].mkv"
  },
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







